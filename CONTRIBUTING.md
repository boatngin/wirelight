# Contributing to Wirelight

Thanks for helping! Bug reports, docs fixes and code are all welcome.

## Ground rules

- Be kind. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- Report security problems privately, see [SECURITY.md](SECURITY.md). Don't open a public issue for them.
- By contributing you agree that your work is released under the project's [MIT License](LICENSE). Sign off your commits (`git commit -s`) to confirm the [Developer Certificate of Origin](https://developercertificate.org/).

## Finding something to work on

Issues labelled [`good first issue`](https://github.com/boatngin/wirelight/labels/good%20first%20issue) or [`help wanted`](https://github.com/boatngin/wirelight/labels/help%20wanted) are a good start. Comment on the issue before you begin so we don't duplicate work.

Area labels tell you where the code lives:

| Label | Code |
|---|---|
| `area/app` | `App/Wirelight` (SwiftUI menu bar app and dashboard) |
| `area/helper` | `Sources/wgbar-helper` (root LaunchDaemon) |
| `area/core` | `Sources/WGCore` (config parser, validation, IPC) |
| `area/installer` | `installer/`, `scripts/` |

## Development setup

See [README › Development](README.md#development). In short:

```bash
brew install wireguard-tools wireguard-go xcodegen
swift build && swift test
cd App && xcodegen generate && open Wirelight.xcodeproj
```

## Pull requests

1. Fork and create a branch from `main` (`fix/…`, `feat/…`, `docs/…`).
2. Keep each PR focused on one change.
3. Add or update tests in `Tests/WGCoreTests` when you touch `WGCore`.
4. Make sure `swift test` passes and the app builds.
5. Use [Conventional Commits](https://www.conventionalcommits.org/) for commit titles, for example `feat(app): …`, `fix(helper): …`.
6. Fill in the PR template, including how you tested.

### Rules for the privileged helper

The helper runs as root, so changes there get extra review:

- Run binaries only through `Shell.run` with a fixed argv. Never build a shell string.
- Never accept file paths from the client.
- Validate every value from the client with `WGCore.Validation`, even if the app already did.
- Never log private keys or full configs.
- Don't support `PreUp`/`PostUp`/`PreDown`/`PostDown` or anything else that runs user-supplied commands.

## Style

- Swift: follow the existing code, 4-space indent, English identifiers and comments.
- UI text: sentence case, short, no exclamation marks.
- Use SF Symbols for UI icons only. Apple's license doesn't allow them in app icons or logos.

## Releases (maintainers)

1. Update `MARKETING_VERSION` in `App/project.yml` if needed.
2. Tag and push: `git tag -a v0.2.0 -m "Wirelight 0.2.0" && git push origin v0.2.0`
3. The **Release** workflow builds `Wirelight.pkg`, the app zip and checksums, then publishes the GitHub release.
