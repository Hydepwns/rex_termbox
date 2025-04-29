# Changelog

Inshalla, this is the last time I'll have to do this.

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
  - `present`, `clear`
  - `width`, `height`
  - `change_cell`, `print` (convenience wrapper around `change_cell`)
  - `get_cell` (uses a shadow buffer maintained by the C process)
  - `set_cursor`
  - `set_input_mode`
  - `set_output_mode`
  - `set_clear_attributes`
- Implemented event handling for key presses, mouse events, and resize events pushed from the C process over UDS.
- Added integration tests (`test/integration`) to verify UDS communication and API functionality.
- Added `DEBUG_SEND_EVENT` command for testing event handling in C.
- Added Python 3.12+ compatibility patch for the `waf` build system used by the `termbox` submodule.

### Fixed

- Resolved various compilation issues and Elixir compiler warnings.
- Addressed `mix test` TTY/stdin inheritance issues during C process startup.
- Ensured `tb_init()` is called at the appropriate time in the C process lifecycle.
- Made command handling case-insensitive in the C port (`strcasecmp`).
- Added missing 'OK' reply for `DEBUG_SEND_EVENT` command in C port.
- Fixed recursive call return bug in `EventManager.handle_info`.
- Corrected regexes in `Protocol.parse_socket_line` (replaced `\\s` with `\s`).
- Fixed GenServer timeout cancellation in `SocketHandler` (returned `:infinity`).
- Fixed `KeyError` on termination by using correct struct update syntax in `CallHandler`.
- Fixed state corruption by correctly merging state updates map in `PortHandler`.

### Removed

- `ExTermbox.Bindings` module and associated NIF code (`c_src/termbox_bindings.c`).
- `ExTermbox.EventManager` module.
- `:expty` dependency.

## [1.0.2] - 2020-03-24

### Fixed

- Compilation errors with 1.0.1 tar (reverted) due to bad file permissions.

## [1.0.1] - 2020-03-15

### Changed

- Updated dependencies (elixir_make, credo).

## [1.0.0] - 2019-03-03

The release includes small breaking changes to the termbox bindings API in order
to make working with the NIFs safer.

Specifically, the termbox bindings have been updated to guard against undefined
behavior (e.g., double initialization, trying to shut it down when it hasn't
been initialized, getting the terminal height when it's not running, etc.). New
errors have been introduced in order to achieve this, and tagged tuples are now
returned in some cases where previously only a raw value returned.

The bindings now prevent polling for events in parallel (i.e., in multiple NIF
threads), which may have caused a segfault before. One way this might have
happened before is when an `EventManager` server crashed and was restarted. The
new API manages a single long-lived polling thread.

### Changed (Breaking)

- All `Bindings` functions (except `init/0`) can now return `{:error, :not_running}`.
- Changed return types for several `Bindings` functions to accomodate new errors:
  - `Bindings.width/1` now returns `{:ok, width}` instead of `width`.
  - `Bindings.height/1` now returns `{:ok, height}` instead of `height`.
  - `Bindings.select_input_mode/1` now returns `{:ok, mode}` instead of `mode`.
  - `Bindings.select_output_mode/1` now returns `{:ok, mode}` instead of `mode`.
- Replaces `Bindings.poll_event/1` with `Bindings.start_polling/1`. The new
  function polls continuously and sends each event to the subscriber. (See also
  `Bindings.stop_polling/0` below.)
- The `EventManager` server, which manages the polling, can now crash if some
  other process is trying to simultaneously manage polling. It will attempt to
  cancel and restart polling once in order to account for the gen_server being
  restarted.

### Added

- `Bindings.stop_polling/0` provides a way to stop and later restart polling
  (for example if the original subscriber process passed to `start_polling/1`
  has died.)

## [0.3.5] - 2019-02-21

### Fixed

- Event manager's default server `name`, which makes it possible to use the
  client API to call the default server without passing a pid.

### Added

- Support for sending the event manager `%Event{}` structs in addition to the
  tuple form that the NIF sends. This provides a convenient way to trigger
  events manually when testing an rex_termbox application.

## [0.3.4] - 2019-02-03

### Added

- Allows passing alternate termobx bindings to `EventManager.start_link/1`,
  which makes it possible to test the event manager's behavior without actually
  calling the NIFs.

## [0.3.3] - 2019-01-26

### Added

- Adds `ExTermbox.EventManager.start_link/1` which supports passing through
  gen_server options.

## [0.3.2] - 2019-01-20

### Added

- Added `:esc_with_mouse` and `:alt_with_mouse` input mode constants.
- Updated documentation and tests for constants.

### Fixed

- Click handling in event viewer demo.

## [0.3.1] - 2019-01-13

### Fixed

- Updated package paths for c_src.

## [0.3.0] - 2019-01-13

### Changed

- Updated termbox to v1.1.2.
- `char` field on `%Cell{}` struct was renamed to `ch` for consistency.

### Removed

- ExTermbox no longer includes a renderer or rendering DSL. Extracted to
  <https://github.com/ndreynolds/ratatouille>
