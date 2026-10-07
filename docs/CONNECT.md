# Connect ChatGPT to your own bridge

Complete installation and choose a narrow disposable project first. The bridge must be **On** during connection.

1. Open Codex Bridge and choose Turn on, or run codex-bridge on on Ubuntu/macOS.
2. Copy the current HTTPS address ending in /mcp. Quick Tunnel addresses can change on every start or recovery; use the address displayed now.
3. In ChatGPT, enable developer mode and add a custom MCP connection using that address. Follow the current [official connection guide](https://developers.openai.com/plugins/deploy/connect-chatgpt). Review the access prompt carefully.
4. Enter the Owner password only in ChatGPT's authorization page. The password is stored locally:
   - Windows: the ownerToken field in the user's .devspace/auth.json file.
   - Ubuntu/macOS: the ownerToken field in the user's XDG config directory at codex-bridge-desktop/devspace/auth.json (normally ~/.config/codex-bridge-desktop/devspace/auth.json).
5. In a disposable folder, perform a read-only file listing. Review each requested tool call. Do not approve shell commands as part of the first smoke test.
6. Turn the bridge Off. Verify the ChatGPT tool is unreachable while the bridge is off.

Never paste the Owner password, a live tunnel URL, an OAuth token, or unredacted logs into a chat message or GitHub issue. If ChatGPT still has an old Quick Tunnel URL after a restart, update or recreate the connection using the newly displayed /mcp address. The browser account and the local bridge credential are separate.