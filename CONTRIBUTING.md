# Contributing during the public beta

Thank you for testing. Please run [docs/TESTING.md](docs/TESTING.md) with a disposable project before using a real codebase.

- Keep the bridge off between tests. Use one narrow root.
- Open a public repository issue with OS, architecture, installed dependency versions, steps, expected result, and observed result.
- Remove personal paths, workspace contents, live tunnel URLs, Owner passwords, OAuth tokens, API keys, and unredacted logs before posting.
- For suspected security issues, contact the repository owner privately instead of opening an issue with exploit details.
- Changes to installers, scope checks, authentication, process cleanup, or external networking need explicit regression checks on each affected platform.
- Do not commit generated binaries, state files, auth files, profiles, or logs. Run the release scan before pushing.

The repository is public. External contributors can fork it and propose changes through pull requests; the owner reviews and merges them.