# Security

This project controls a remote bridge. It cannot promise perfect security. Treat every public tunnel as a temporary attack surface and turn it off when the session ends.

## Actual boundary

DevSpace's AllowedRoots limits its file tools. **It does not sandbox the shell tool.** After OAuth authorization, an MCP client can run commands with the permissions of the local account running DevSpace. A narrow folder is useful but is not an OS security boundary. For sensitive work, run the bridge under a separate least-privilege OS account or disposable VM with only a test project mounted.

ChatGPT project membership, agent instructions, and read-only prompts are policy controls; they are not enforced by DevSpace's shell tool. A malicious prompt injection in project files may try to induce unauthorized tool use. Review tool calls and use a disposable workspace for the initial test.

## Defaults and local data

- The bridge is off after installation. The installer does not create a public tunnel.
- Windows sets one explicit project root and one identical allowed root. The upstream controller checks broad roots in Doctor.
- Unix writes one allowed root and isolated DevSpace config under the user's XDG config directory. The Owner password is generated locally with a cryptographic RNG and stored in a mode-0600 file.
- Runtime profiles, owner passwords, OAuth state, logs, public URLs, and PIDs are never tracked in Git. The ignore file excludes build and runtime output; a separate release scan checks tracked content.
- The temporary Quick Tunnel uses a changing URL. Anyone can reach its network endpoint while it runs, but an OAuth grant is required for MCP tools. A stolen owner password or token changes that risk.
- Off preserves authorization data so reconnecting is easier. For suspected compromise, stop the bridge, use upstream Rotate on Windows, and revoke/reconnect the ChatGPT app. Unix beta currently requires deleting its isolated OAuth state and regenerating the Owner token manually after Off.

## Supply chain and platform limits

The Windows installer pins the upstream Git commit and DevSpace version. The Unix installer pins DevSpace and Python build dependencies, but cloudflared remains an external prerequisite. Review downloads and hashes before a wider release. GitHub Actions and macOS signing/notarization are not yet release gates.

The Ubuntu and macOS paths are beta implementations. Their tunnel lifecycle and packaging need independent native tests. Do not advertise the whole product as audited, formally verified, or 100% secure.

## Reporting a vulnerability

During the private beta, contact the repository owner privately through GitHub. Do not include secrets, tokens, live tunnel addresses, or exploit payloads in a public issue. Turn off the bridge immediately if you suspect unauthorized access.