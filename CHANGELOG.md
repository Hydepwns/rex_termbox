# Changelog

Inshalla, this is the last time I'll have to do this.

## [Unreleased]

### Known Issues / TODO

- Resolve compiler warnings about unused private `_parse_*` helper functions in `ExTermbox.Protocol`.
- Investigate and fix warnings about potentially unreachable clauses (`{:parse_error, ...}`, `{:unknown_line, ...}`) in `ExTermbox.PortHandler.SocketHandler.process_socket_line/3`, possibly due to incomplete return types from `ExTermbox.Protocol.parse_socket_line/1`.
- Enhance example tests (`test/integration/examples_test.exs`) to verify visual output or behavior beyond just startup.

## [1.1.5] - 2025-05-01

### Fixed

- Corrected the packaging configuration in `mix.exs` by removing the explicit inclusion of a `waf` build artifact file (`c_src/termbox/.waf3-..../waflib/Utils.py`). This artifact prevented the main `waf` script (which contains the complete, patched `waflib`) from correctly unpacking its embedded library during dependency compilation, leading to an `ImportError: cannot import name 'Scripting' from 'waflib'` when using v1.1.4.

## [1.1.4] - 2025-04-30

### Fixed

- Ensured the patched `waf` utility script (`waflib/Utils.py`) is correctly included in the Hex package by updating the `files` list in `mix.exs`. This resolves the build failure reported in `v1.1.3` where the Python 3.9+ compatibility fix was not being applied during dependency compilation.

## [1.1.3] - 2025-04-30

### Fixed

- Patched the `waf` build script (`waflib/Utils.py`) within the included `termbox` C library submodule to ensure compatibility with Python 3.9+. This resolves build failures caused by the removal of the 'U' file mode and issues with specifying encoding for binary files.

## [1.1.2] - 2025-04-30

### Fixed

- Resolved `tb_init()` failure when the C helper process (`termbox_port`) was launched via Elixir Ports. The underlying `termbox` library requires a controlling TTY, which was not available in the standard Port environment. This was fixed by replacing the Port spawning mechanism with the `ExPTY` library.

### Changed

- Replaced direct use of `Port.open` in `ExTermbox.PortHandler` with `ExPTY.spawn`.
- Refactored `ExTermbox.PortHandler` to handle process interaction via `ExPTY` callbacks (`on_data`, `on_exit`) instead of Port messages.
- Added `:expty_pid` field to `ExTermbox.PortHandler.State` and removed the `:port` field.
- Implemented buffering for data received from `ExPTY` during initialization using `ExTermbox.Buffer`.
- Updated `ExTermbox.PortHandler` shutdown logic to send a `"shutdown\n"` command via the UDS socket instead of attempting to close an Erlang Port.
- Reverted previous attempts to manually acquire a TTY in `c_src/termbox_port.c` using `setsid` and `ioctl`; the C code now uses the standard `tb_init()` again, relying on the pty environment provided by `ExPTY`.

### Added

- Added `expty` as a dependency.

## [1.1.1] - 2025-04-30

### Fixed

- Resolved integration test failures:
  - Added `Process.flag(:trap_exit, true)` to the C process crash test (`test/integration/ex_termbox_integration_test.exs`) to prevent the test process from exiting prematurely.
  - Improved JSON-like event string parsing in `ExTermbox.Protocol.parse_simple_json_like/1` to correctly handle braces and potential integer conversion errors, fixing the synthetic event test.
- Refined `ExTermbox.PortHandler.TerminationHandler` to remove outdated Erlang Port cleanup logic, relying on standard process linking for `ExPTY` process termination.
- Removed unused private helper functions (`_parse_*`) from `ExTermbox.Protocol` to resolve compiler warnings.

## [1.1.0] - 2025-04-29

### Changed (Breaking)

- Complete architectural overhaul: Replaced NIF-based bindings (`ExTermbox.Bindings`) with a managed C helper process (`termbox_port`) using Elixir Ports for initialization and Unix Domain Sockets (UDS) for runtime communication.
- Public API moved from `ExTermbox.Bindings` to the main `ExTermbox` module.
- Removed direct NIF functions like `ExTermbox.Bindings.poll_event/1`.
- Event handling is now asynchronous via messages (`{:termbox_event, event_map}`) sent to the process that called `ExTermbox.init/1`.
- Removed `ExTermbox.EventManager` as event polling is now handled internally by the Port/UDS system.

### Added

- New C helper program `c_src/termbox_port.c` responsible for calling termbox functions.
- Elixir `ExTermbox.PortHandler` GenServer to manage the C process and UDS communication.
- Internal modules for handling protocol, buffering, and process management (`ExTermbox.Protocol`, `ExTermbox.Buffer`, `ExTermbox.ProcessManager`, etc.).
- Implemented support for the following termbox functionalities via the new architecture:
  - `init`, `shutdown`