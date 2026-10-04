# Grok Desk

An independent, unofficial native macOS client for Grok Build, built with SwiftUI and AppKit. Not affiliated with or endorsed by xAI. Grok and related names belong to their respective owners.

## Features

- Workspace-based chats, agent activity and prompt queues
- Cinema Studio for image/video workflows through your installed Grok tools
- Browser, terminal, files and repository panels
- Connections, configuration and project-rule editors
- Scheduled routines with an optional local helper
- Animated glass UI, live appearance controls and Performance Mode

This is early-stage software. Provider features depend on your installed Grok Build version and account. Some workflows open the official Grok terminal interface.

## Requirements

- macOS 14 or later (native glass effects use macOS 26 when available)
- Xcode with Swift 6 and the Metal compiler/toolchain
- A separately installed Grok Build CLI and your own signed-in account

No credentials, sessions, account configuration, generated media, or CLI binaries are included.

## Build and run

```sh
bash scripts/build-shaders.sh
swift build
swift run GrokDesk
```

If Xcode reports a missing Metal toolchain, install that component through Xcode first.

## Test and package

```sh
bash scripts/build-shaders.sh
swift test
bash scripts/package-app.sh
```

The package script creates `dist/Grok Desk.app` with local ad-hoc signing. It is not Developer ID signed or notarized. Set `GROK_APP_ICON` to your own `.icns` file to customize the optional icon.

## Privacy and security

The app reads your local Grok installation, configuration and session data at runtime. These remain outside this repository. Use your own `grok login` flow. Never commit your `.grok` directory, authentication files, environment files or generated logs.

Connections and agent tools can access files and external services according to the permissions you grant. Review those permissions before enabling tools or unattended routines.

## Contributing

Keep changes focused. Test meaningful behavior and failure cases; verify UI changes in the native app. Do not include personal paths, transcripts, screenshots with account details, or credentials in issues and pull requests.

Dependency licenses are in `docs/THIRD-PARTY-NOTICES.txt`.

## License

MIT; see `LICENSE`. Third-party components retain their own licenses. No rights to third-party trademarks are granted.
