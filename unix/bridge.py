#!/usr/bin/env python3
"""Local, off-by-default DevSpace + Quick Tunnel controller for Unix beta."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

import psutil

APP = "codex-bridge-desktop"
CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / APP
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / APP
SETTINGS = CONFIG_HOME / "settings.json"
DEVSPACE_HOME = CONFIG_HOME / "devspace"
STATE = STATE_HOME / "state.json"
URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
OPTIONS = {"5m": 5, "10m": 10, "15m": 15, "30m": 30,
           "1h": 60, "2h": 120, "8h": 480, "never": 0}


def save_json(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(path.name + f".{os.getpid()}.{secrets.token_hex(4)}.tmp")
    with temp.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
    os.chmod(temp, 0o600)
    temp.replace(path)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def checked_root(text: str) -> Path:
    candidate = Path(text).expanduser()
    if not candidate.is_dir() or candidate.is_symlink():
        raise ValueError("Choose an existing real project directory, not a link.")
    root = candidate.resolve(strict=True)
    home = Path.home().resolve(strict=True)
    if root == Path(root.anchor) or root == home or root in home.parents:
        raise ValueError("Choose a narrow project folder, not a filesystem or home root.")
    return root


def settings() -> dict:
    data = load_json(SETTINGS)
    if not data.get("projectRoot"):
        raise RuntimeError("Run configure with an approved project folder first.")
    data["projectRoot"] = str(checked_root(data["projectRoot"]))
    if data.get("autoOff", "1h") not in OPTIONS:
        raise RuntimeError("Invalid auto-off setting.")
    return data


def live_process(record: dict | None) -> psutil.Process | None:
    if not record:
        return None
    try:
        process = psutil.Process(int(record["pid"]))
        if abs(process.create_time() - float(record["created"])) < 1:
            return process
    except (KeyError, ValueError, TypeError, psutil.Error):
        pass
    return None


def process_record(process: psutil.Process) -> dict:
    return {"pid": process.pid, "created": process.create_time()}


def stop_record(record: dict | None) -> None:
    process = live_process(record)
    if not process:
        return
    try:
        process.terminate()
        process.wait(timeout=8)
    except psutil.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)
    except psutil.Error:
        pass


def response_status(url: str) -> int:
    try:
        with urllib.request.urlopen(urllib.request.Request(url), timeout=8) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except (urllib.error.URLError, TimeoutError):
        return 0


def healthy(base: str) -> bool:
    return (response_status(base + "/.well-known/oauth-protected-resource/mcp") == 200
            and response_status(base + "/mcp") in (200, 401))


def prepare_devspace(root: str, public_url: str) -> None:
    DEVSPACE_HOME.mkdir(mode=0o700, parents=True, exist_ok=True)
    auth = DEVSPACE_HOME / "auth.json"
    if not auth.exists():
        save_json(auth, {"ownerToken": secrets.token_urlsafe(32)})
    config = {
        "host": "127.0.0.1", "port": 7676,
        "allowedRoots": [root], "publicBaseUrl": public_url,
    }
    save_json(DEVSPACE_HOME / "config.json", config)


def start_pair(root: str, devspace_command: str) -> tuple[subprocess.Popen, subprocess.Popen, str]:
    STATE_HOME.mkdir(mode=0o700, parents=True, exist_ok=True)
    tunnel_log = STATE_HOME / "tunnel.log"
    tunnel_log.write_text("", encoding="utf-8")
    os.chmod(tunnel_log, 0o600)
    with tunnel_log.open("ab", buffering=0) as stream:
        tunnel = subprocess.Popen(
            ["cloudflared", "tunnel", "--url", "http://127.0.0.1:7676",
             "--no-autoupdate", "--no-prechecks", "--logfile", str(tunnel_log), "--loglevel", "info"],
            stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
            start_new_session=True,
        )
    tunnel_started = psutil.Process(tunnel.pid).create_time()
    try:
        public_url = ""
        for _ in range(45):
            if tunnel.poll() is not None:
                raise RuntimeError("Cloudflare tunnel exited before providing an address.")
            found = URL_RE.search(tunnel_log.read_text(encoding="utf-8", errors="replace"))
            if found:
                public_url = found.group(0)
                break
            time.sleep(1)
        if not public_url:
            raise RuntimeError("Cloudflare tunnel did not provide an address.")
        prepare_devspace(root, public_url)
        environment = os.environ.copy()
        environment["DEVSPACE_CONFIG_DIR"] = str(DEVSPACE_HOME)
        environment["DEVSPACE_STATE_DIR"] = str(STATE_HOME / "devspace-state")
        environment["DEVSPACE_WORKTREE_ROOT"] = str(STATE_HOME / "worktrees")
        environment["DEVSPACE_LOG_SHELL_COMMANDS"] = "false"
        devspace_log = STATE_HOME / "devspace.log"
        with devspace_log.open("ab", buffering=0) as stream:
            os.chmod(devspace_log, 0o600)
            devspace = subprocess.Popen(
                [devspace_command, "serve"], env=environment,
                stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                start_new_session=True,
            )
        devspace_started = psutil.Process(devspace.pid).create_time()
        try:
            for _ in range(40):
                if devspace.poll() is not None or tunnel.poll() is not None:
                    raise RuntimeError("DevSpace or Cloudflare exited during startup.")
                if healthy("http://127.0.0.1:7676") and healthy(public_url):
                    return tunnel, devspace, public_url + "/mcp"
                time.sleep(1)
            raise RuntimeError("Local and tunnel health checks did not pass.")
        except Exception:
            stop_record({"pid": devspace.pid, "created": devspace_started})
            raise
    except Exception:
        stop_record({"pid": tunnel.pid, "created": tunnel_started})
        raise


def daemon() -> int:
    data = settings()
    state = load_json(STATE)
    if state.get("desired") != "running":
        return 0
    deadline = state.get("deadline")
    devspace_command = data.get("devspaceCommand") or shutil_which("devspace")
    if not devspace_command:
        raise RuntimeError("Pinned DevSpace executable is missing.")
    retries = 0
    tunnel = None
    devspace = None

    def closing(_signum, _frame):
        save_json(STATE, {**load_json(STATE), "desired": "stopped"})
    signal.signal(signal.SIGTERM, closing)
    signal.signal(signal.SIGINT, closing)
    try:
        while load_json(STATE).get("desired") == "running":
            if deadline and time.time() >= deadline:
                break
            try:
                tunnel, devspace, mcp_url = start_pair(data["projectRoot"], devspace_command)
                save_json(STATE, {**load_json(STATE), "status": "healthy",
                                  "mcpUrl": mcp_url, "retries": retries,
                                  "tunnel": process_record(psutil.Process(tunnel.pid)),
                                  "devspace": process_record(psutil.Process(devspace.pid))})
                retries = 0
                last_health_check = 0.0
                while load_json(STATE).get("desired") == "running":
                    if deadline and time.time() >= deadline:
                        break
                    if tunnel.poll() is not None or devspace.poll() is not None:
                        raise RuntimeError("A managed process exited.")
                    if time.time() - last_health_check >= 30:
                        if not healthy(mcp_url.removesuffix("/mcp")):
                            raise RuntimeError("The public endpoint became unhealthy.")
                        last_health_check = time.time()
                    time.sleep(2)
                if deadline and time.time() >= deadline:
                    break
            except Exception as error:
                retries += 1
                save_json(STATE, {**load_json(STATE), "status": "recovering",
                                  "mcpUrl": None, "retries": retries,
                                  "error": str(error)})
                if retries >= 3:
                    save_json(STATE, {**load_json(STATE), "status": "failed",
                                      "desired": "stopped"})
                    break
                time.sleep(min(2 ** retries, 8))
            finally:
                if devspace:
                    stop_record(load_json(STATE).get("devspace"))
                if tunnel:
                    stop_record(load_json(STATE).get("tunnel"))
                devspace = None
                tunnel = None
        return 0
    finally:
        save_json(STATE, {**load_json(STATE), "desired": "stopped",
                          "status": "off", "mcpUrl": None,
                          "devspace": None, "tunnel": None})


def configure(args) -> None:
    root = checked_root(args.root)
    prior = load_json(SETTINGS)
    auto_off = args.auto_off or prior.get("autoOff", "1h")
    if auto_off not in OPTIONS:
        raise ValueError("Choose one of: " + ", ".join(OPTIONS))
    devspace_command = args.devspace_command or prior.get("devspaceCommand")
    if devspace_command and not Path(devspace_command).is_file():
        raise ValueError("DevSpace executable does not exist.")
    save_json(SETTINGS, {"projectRoot": str(root), "autoOff": auto_off,
                         "devspaceCommand": devspace_command})
    print("Configured one approved root:", root)
    print("Bridge is off; run on when you are ready.")


def on() -> None:
    data = settings()
    devspace_command = data.get("devspaceCommand") or shutil_which("devspace")
    if not devspace_command or not shutil_which("cloudflared"):
        raise RuntimeError("Install pinned DevSpace and cloudflared first; see README.md.")
    current = load_json(STATE)
    if live_process(current.get("daemon")):
        print("Bridge supervisor is already running.")
        return
    for name in ("devspace", "tunnel"):
        stop_record(current.get(name))
    duration = OPTIONS[data.get("autoOff", "1h")]
    deadline = time.time() + duration * 60 if duration else None
    save_json(STATE, {"desired": "running", "status": "starting",
                      "deadline": deadline, "mcpUrl": None})
    command = [sys.executable]
    if not getattr(sys, "frozen", False):
        command.append(str(Path(__file__).resolve()))
    command.append("daemon")
    log = STATE_HOME / "controller.log"
    with log.open("ab", buffering=0) as stream:
        os.chmod(log, 0o600)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=stream,
                                   start_new_session=True)
    save_json(STATE, {**load_json(STATE), "daemon": process_record(psutil.Process(process.pid))})
    for _ in range(90):
        current = load_json(STATE)
        if current.get("status") == "healthy":
            print("Bridge is on:", current["mcpUrl"])
            return
        if current.get("status") == "failed" or process.poll() is not None:
            raise RuntimeError("Start failed. See local controller.log and status.")
        time.sleep(1)
    raise RuntimeError("Start is still pending. Run status to inspect.")


def off() -> None:
    current = load_json(STATE)
    save_json(STATE, {**current, "desired": "stopped"})
    supervisor = live_process(current.get("daemon"))
    if supervisor:
        try:
            supervisor.terminate()
            supervisor.wait(timeout=15)
        except psutil.TimeoutExpired:
            supervisor.kill()
        except psutil.Error:
            pass
    for name in ("devspace", "tunnel"):
        stop_record(current.get(name))
    save_json(STATE, {**load_json(STATE), "desired": "stopped", "status": "off",
                      "mcpUrl": None, "devspace": None, "tunnel": None})
    print("Bridge and tunnel are off.")


def rotate() -> None:
    before = load_json(STATE)
    off()
    if any(live_process(before.get(name)) for name in ("daemon", "devspace", "tunnel")):
        raise RuntimeError("A managed process remains; OAuth revocation is incomplete.")
    database = STATE_HOME / "devspace-state" / "devspace.sqlite"
    for path in (database, Path(str(database) + "-wal"), Path(str(database) + "-shm")):
        if path.exists():
            path.unlink()
    save_json(DEVSPACE_HOME / "auth.json", {"ownerToken": secrets.token_urlsafe(32)})
    print("Bridge is off. OAuth database cleared and Owner password rotated.")

def status() -> None:
    current = load_json(STATE)
    supervisor = live_process(current.get("daemon"))
    reported = current.get("status", "off")
    if reported == "healthy" and not supervisor:
        reported = "unhealthy"
    print(json.dumps({
        "status": reported,
        "supervisorRunning": bool(supervisor),
        "mcpUrl": current.get("mcpUrl") if supervisor else None,
        "autoOff": load_json(SETTINGS).get("autoOff"),
        "retries": current.get("retries", 0),
    }, indent=2))


def shutil_which(name: str) -> str | None:
    from shutil import which
    return which(name)


def menu() -> None:
    while True:
        print("\nCodex Bridge: 1 On  2 Off  3 Status  4 Quit")
        choice = input("> ").strip()
        if choice == "1":
            on()
        elif choice == "2":
            off()
        elif choice == "3":
            status()
        elif choice == "4":
            return


def main() -> int:
    parser = argparse.ArgumentParser(description="Codex Bridge Unix beta controller")
    commands = parser.add_subparsers(dest="action", required=True)
    config = commands.add_parser("configure")
    config.add_argument("--root", required=True)
    config.add_argument("--auto-off", choices=OPTIONS)
    config.add_argument("--devspace-command")
    for action in ("on", "off", "status", "doctor", "menu", "daemon", "rotate"):
        commands.add_parser(action)
    args = parser.parse_args()
    try:
        if args.action == "configure":
            configure(args)
        elif args.action == "on":
            on()
        elif args.action == "off":
            off()
        elif args.action == "status":
            status()
        elif args.action == "rotate":
            rotate()
        elif args.action == "doctor":
            print("DevSpace:", settings().get("devspaceCommand") or shutil_which("devspace") or "missing")
            print("Cloudflared:", shutil_which("cloudflared") or "missing")
            print("Approved root:", settings()["projectRoot"])
        elif args.action == "menu":
            menu()
        elif args.action == "daemon":
            return daemon()
        return 0
    except (ValueError, RuntimeError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())