# FILES

_\$XDG_CONFIG_HOME/hallows/config.hallows_

: Location of the default configuration file.

_\$HOME/Library/Application Support/app.hallows/config.hallows_

: Location of the default configuration file. This location takes
precedence over the XDG environment locations.

# ENVIRONMENT

**TERM**

: Defaults to `xterm-hallows`. Can be configured with the `term` configuration option.

**HALLOWS_RESOURCES_DIR**

: Where the Hallows resources can be found.

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/app.hallows**

: Default location for configuration files. This location takes
precedence over the XDG environment locations.


**HALLOWS_LOG**

: The `HALLOWS_LOG` environment variable can be used to control which
destinations receive logs. Hallows currently defines two destinations:

: - `stderr` - logging to `stderr`.
: - `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

: Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `HALLOWS_LOG` to `true` will enable all
destinations. Setting `HALLOWS_LOG` to `false` will disable all destinations.

# BUGS

See GitHub issues: <https://github.com/ghostty-org/ghostty/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Ghostty contributors <https://github.com/ghostty-org/ghostty/graphs/contributors>

# SEE ALSO

**hallows(5)**
