# Hallows

Hallows is a terminal emulator for macOS on Apple Silicon. It's a fork of
[Ghostty](https://github.com/ghostty-org/ghostty) that keeps Ghostty's fast,
standards-compliant terminal core and native macOS app, and adds:

- **Persistent ssh sessions without tmux.** `hallows +ssh --persist` keeps
  the remote shell alive across dropped connections using `hallows-persist`,
  a small session daemon the app copies to the remote host (Linux, x86_64
  and aarch64). Reconnecting redraws the screen, including output missed
  while disconnected.
- **A file tree sidebar** that follows the focused terminal, locally and
  over ssh, with git status and an "open in editor" split.
- **Program status** (OSC 7501) shown in the app, so programs such as AI
  agents can report what they're doing.
- **One fixed look**: panes are cards with headers floating over a warm,
  blurred window. Theming and appearance options are not configurable.

Hallows only runs on Apple Silicon Macs. There are no Linux, Windows, or
Intel builds of the app.

## Building

Building requires an Apple Silicon Mac with Zig 0.16 and Xcode (with the
macOS SDK and Metal Toolchain) installed.

| Command            | Description                                    |
| ------------------ | ---------------------------------------------- |
| `zig build`        | Builds the app into `zig-out/Hallows.app`      |
| `zig build run`    | Builds and runs the app                        |
| `zig build test`   | Runs unit tests (`-Dtest-filter=<filter>`)     |
| `zig build test-vt`| Runs the terminal module (`ghostty-vt`) tests  |

See [HACKING.md](HACKING.md) for more development details.

## Crash Reports

Hallows has a built-in crash reporter that saves crash reports to disk
under `$XDG_STATE_HOME/hallows/crash` (`~/.local/state` if
`$XDG_STATE_HOME` is not set). **Crash reports are _not_ sent anywhere off
your machine.** Reports are generated the next time Hallows starts after a
crash. Use `hallows +crash-report` to list them.

Crash reports end in the `.ghosttycrash` extension and are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/).

> [!WARNING]
>
> The crash report can contain sensitive information. It contains the full
> stack memory of each thread at the time of the crash.

## License

Hallows is based on Ghostty and is released under the same
[MIT license](LICENSE).
