# Cohort and release plan

1. This repository is public. Share its GitHub URL with 3-5 named testers; no collaborator invitation is needed to read or clone it. Start with Windows testers using disposable projects; the Windows tray is the only locally exercised full app.
2. Give each tester the README and security model before connecting ChatGPT. Ask them to run the checklist and report OS, build, and lifecycle results in public issues. They must remove personal paths, credentials, tunnel URLs, project content, and unredacted logs before posting.
3. Add one Ubuntu and one macOS tester specifically for native build, launcher, process cleanup, auto-off, and OAuth connection. Treat those platforms as experimental until their results pass.
4. Outside contributors can fork the repository and open pull requests. Keep direct write access with the owner, review every proposed change, and repeat the relevant smoke tests before merging.
5. Before a tagged beta release or wider promotion, review every commit and release artifact, run the secret scan, verify licenses and dependency pins, and check unsigned-app warnings. Seek an independent security review of the remote shell exposure before recommending this for sensitive projects.
