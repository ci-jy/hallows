# Developing Hallows

This document describes the technical details behind Hallows' development.
Hallows is a fork of Ghostty for macOS on Apple Silicon.

When you're developing Hallows, it's very likely that you will want to build a
_debug_ build to diagnose issues more easily. This is already the default for
Zig builds, so simply run `zig build` **without any `-Doptimize` flags**.

There are many more build steps than just `zig build`, some of which are listed
here:

| Command             | Description                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| `zig build run`     | Runs Hallows                                                                                       |
| `zig build test`    | Runs unit tests (accepts `-Dtest-filter=<filter>` to only run tests whose name matches the filter) |
| `zig build test-vt` | Runs the `ghostty-vt` terminal module tests (used by `hallows-persist`)                            |

Hallows only builds on an Apple Silicon Mac with Zig 0.16. The app and its
library are arm64 only; `hallows-persist` is additionally cross-compiled for
x86_64 and aarch64 Linux, since it runs on the remote hosts.

## Extra Dependencies

Building the Hallows macOS app requires that Xcode, the macOS SDK,
and Metal Toolchain are all installed.

A common issue is that the incorrect version of Xcode is either
installed or selected. Use the `xcode-select` command to
ensure that the correct version of Xcode is selected:

```shell-session
sudo xcode-select --switch /Applications/Xcode.app
```

> [!IMPORTANT]
>
> Development of Hallows requires **Xcode 26 and the macOS 26 SDK**.
>
> You do not need to be running on macOS 26 to build Hallows, you can
> still use Xcode 26 on macOS 15 stable.

## Logging

Hallows can log to `stderr` and to the macOS unified log, which is enabled by
default. Use the system `log` CLI to view Hallows' logs:
`sudo log stream --level debug --predicate 'subsystem=="app.hallows"'`.

Hallows' logging can be configured in two ways. The first is by what
optimization level Hallows is compiled with. If Hallows is compiled with `Debug`
optimizations debug logs will be output to `stderr`. If Hallows is compiled with
any other optimization the debug logs will not be output to `stderr`.

Hallows also checks the `HALLOWS_LOG` environment variable. It can be used
to control which destinations receive logs. Hallows currently defines two
destinations:

- `stderr` - logging to `stderr`.
- `macos` - logging to macOS's unified log.

Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `HALLOWS_LOG` to `true` will enable all
destinations. Setting `HALLOWS_LOG` to `false` will disable all destinations.

## Linting

### Prettier

Hallows' docs and resources (not including Zig code) are linted using
[Prettier](https://prettier.io) with out-of-the-box settings. A Prettier CI
check will fail builds with improper formatting. Therefore, if you are
modifying anything Prettier will lint, you may want to install it locally and
run this from the repo root before you commit:

```
prettier --write .
```

### ShellCheck

Bash scripts are checked with [ShellCheck](https://www.shellcheck.net/).
[Install ShellCheck](https://github.com/koalaman/shellcheck#user-content-installing) and then run:

```
shellcheck \
    --check-sourced \
    --severity=warning \
    $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)
```

### SwiftLint

Swift code is linted using [SwiftLint](https://github.com/realm/SwiftLint). A
SwiftLint CI check will fail builds with improper formatting. Therefore, if you
are modifying Swift code, you may want to install it locally and run this from
the repo root before you commit:

```
swiftlint lint --fix
```

To check for violations without auto-fixing:

```
swiftlint lint --strict
```

## Input Stack Testing

The input stack is the part of the codebase that starts with a
key event and ends with text encoding being sent to the pty (it
does not include _rendering_ the text, which is part of the
font or rendering stack).

If you modify any part of the input stack, you must manually verify
all the following input cases work properly. We unfortunately do
not automate this in any way, but if we can do that one day that'd
save a LOT of grief and time.

Note: this list may not be exhaustive, I'm still working on it.

### IME

IME (Input Method Editors) are a common source of bugs in the input stack.
Test dead key input (e.g. Spanish), CJK (e.g. Japanese), emoji, and Unicode
Hex Input.

> [!NOTE]
>
> This is a **work in progress**. I'm still working on this list and it
> is not complete. As I find more test cases, I will add them here.

#### Dead Key Input

Set your keyboard layout to "Spanish" (or another layout that uses dead keys).

1. Launch Hallows
2. Press `'`
3. Press `a`
4. Verify that `á` is displayed

Note that the dead key may or may not show a preedit state visually.
Importantly, the text should be correct when it is sent to the pty.

We should also test canceling dead key input:

1. Launch Hallows
2. Press `'`
3. Press escape
4. Press `a`
5. Verify that `a` is displayed (no diacritic)

#### CJK Input

Add a Japanese input source in System Settings. The exact layout doesn't
matter.

1. Launch Hallows
2. Switch to the "Hiragana" input source
3. On a US physical layout, type: `konn`, you should see `こん` in preedit.
4. Press `Enter`
5. Verify that `こん` is displayed in the terminal.

We should also test switching input methods while preedit is active, which
should commit the text:

1. Launch Hallows
2. Switch to the "Hiragana" input source
3. On a US physical layout, type: `konn`, you should see `こん` in preedit.
4. Switch to another input source (any)
5. Verify that `こん` is displayed in the terminal as committed text.
