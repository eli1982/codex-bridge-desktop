# Troubleshooting

## Installer stops before setup

Check each prerequisite in the README. Windows uses the pinned upstream skill and a standard per-user npm CLI path. The installer refuses to overwrite an incompatible skill or silently downgrade a different DevSpace version. Ubuntu/macOS build DevSpace in a user-local directory. Do not work around version checks by deleting existing programs without a backup.

## On fails or stays in recovery

Run the app's Status and Doctor actions. Confirm the selected project folder still exists, one allowed root is configured, and no broad-root security warning is present. Check that port 7676 is not owned by an unrelated process. Inspect local logs only; redact their contents before sharing.

## ChatGPT cannot connect after a restart

A Quick Tunnel can receive a new address. Use the current HTTPS address ending in /mcp. Update the ChatGPT connection if necessary. A 401 response from the MCP endpoint can be the expected unauthenticated health response; it is different from a Codex or OpenAI API key rejection.

## Off or Exit is stuck

Windows: try the tray Exit action, then the installed Kill Codex Bridge executable. The kill tool targets the bridge's named host and verified tray process. Ubuntu/macOS: run codex-bridge off. If shutdown cannot be verified, keep the ChatGPT connection disconnected and report the failure privately.

## Suspected unauthorized access

Keep the bridge off. Run bridge.cmd Rotate on Windows or codex-bridge rotate on Ubuntu/macOS. Rotation clears saved DevSpace OAuth state and changes the Owner password. Reconnect ChatGPT afterward. The saved DevSpace workspace database is reset; project source files are not deleted. If Rotate reports an error, assume revocation is incomplete and ask the maintainer for help before reconnecting.