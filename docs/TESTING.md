# Private beta test checklist

Use a disposable folder with no secrets. Start with the bridge **off** and one narrow allowed root.

1. Install using the platform instructions. Record OS version, CPU architecture, Node version, and whether the build succeeds. Do not paste personal paths into issues.
2. Confirm the app starts with the bridge off. On Windows, check the tray icon and Task Manager entry. On Ubuntu/macOS, check the launcher and status.
3. Turn on. Verify the local and public MCP endpoints return the expected 200/401 health contract. Note whether the URL changes.
4. Connect ChatGPT using the current URL and the locally stored Owner password. Perform a read-only listing of a disposable test file. Do not approve shell commands for the first smoke test.
5. Turn off. Confirm the local listener, DevSpace process, and tunnel process are gone. Try the ChatGPT tool again; it should fail to reach the bridge.
6. Test intentional exit while already off. On Windows, confirm Exit closes promptly. Test the Kill executable only on the tester's own bridge processes.
7. With a short auto-off setting, confirm it stops at the selected deadline. For recovery, terminate the owned tunnel and confirm no more than three retries during the active window. Expect a new temporary URL.
8. With the bridge off and a disposable DevSpace state, test Rotate. Confirm the old OAuth grant fails and the Owner password changes. Rotation clears the saved DevSpace workspace database.
9. Reinstall over the test installation. Confirm it does not silently widen the allowed root or overwrite a different upstream version.

Report failures with steps to reproduce, expected and actual behavior, and redacted logs. Remove Owner passwords, OAuth tokens, live tunnel URLs, personal project names, and private file contents. Prefix issues with the platform. Do not submit sensitive data through GitHub issues.