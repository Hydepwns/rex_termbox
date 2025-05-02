# Changelog

Inshalla, this is the last time I'll have to do this.

## [Unreleased]

*No changes yet.*

## [2.0.2] - YYYY-MM-DD

### Fixed

- Prevent infinite warning loop in `ExTermbox.Server` when `tb_peek_event` NIF returns `{-6, 0, 0, 0}`. The server now specifically handles this tuple as a polling error, logs a warning, and uses a slightly longer interval (`@poll_error_interval_ms`) before rescheduling the poll to avoid log spam and reduce load during persistent errors.

## [2.0.1] - 2024-07-29

### Fixed

- Fixed the `get_cell/2` implementation to properly handle the missing NIF function.
  The function now returns `{:error, {:not_implemented, "..."}}` instead of failing.
- Updated documentation to clarify that `get_cell/2` is not currently implemented
  in the underlying NIF library.
- Fixed test expectations for `get_cell/2` to match the new behavior.
- Removed invalid `Mox.start()` call from test helper.

## [2.0.0] - 2023-06-12

### Breaking Changes

- **Complete Architectural Overhaul:** Replaced the previous Port/UDS architecture (using a C helper process, `:expty`, and Unix Domain Sockets) with a direct NIF-based integration using the `termbox2` library (via the `Hydepwns/termbox2-nif` fork).
- **API Interaction:** Public API functions in `ExTermbox` now interact with a `GenServer` (`ExTermbox.Server`) instead of directly managing a port/process. Functions like `init/1`, `shutdown/0`, `width/0`, `height/0`, etc., now primarily send messages to this server.
- **Event Handling:** Event polling is now handled internally by `ExTermbox.Server` using the `tb_peek_event` NIF. Events are delivered asynchronously as `{:termbox_event, %ExTermbox.Event{}}` messages to the process that called `init/1` (the owner process). Manual event polling functions (`poll_event`, `peek_event`) have been removed.
- **Dependencies:**
  - Removed the `:expty` dependency.
  - Removed the `:elixir_make` dependency and associated build configurations (`Makefile`, C helper build logic).
  - Added a dependency on `termbox2` (currently requiring the `Hydepwns/termbox2-nif` fork with `submodules: true`).
- **Removed Modules:** All modules related to the old Port/UDS architecture have been removed, including:
  - `ExTermbox.PortHandler` and its sub-modules (`InitHandler`, `SocketHandler`, etc.)
  - `ExTermbox.ProcessManager`
  - `ExTermbox.Buffer`
  - `ExTermbox.Protocol`
  - `ExTermbox.Initializer`
  - `ExTermbox.EventManager`
  - The C helper program (`c_src/termbox_port.c`) and the `termbox` C library submodule.

### Added

- **`ExTermbox.Server`:** A new `GenServer` responsible for managing the `termbox2` lifecycle (`tb_init`, `tb_shutdown`), handling API calls via NIFs, and polling/dispatching events.
- **`ExTermbox.Event`:** A struct representing parsed terminal events.
- **`ExTermbox.Constants`:** Module defining constants for keys, colors, attributes, modes, etc., based on `termbox2`.
- **NIF Integration:** The library now directly calls NIF functions provided by the `termbox2` dependency (fork).
- **`get_cell/2`:** Added function to retrieve cell content (requires corresponding NIF in the fork).
- **Unit Tests:** Added unit tests for `ExTermbox.Server`, particularly for event handling logic, using mocked NIF calls.

### Changed

- **`mix.exs`:** Updated dependencies and removed old build configurations.
- **API Functions:** Refactored implementations of all `ExTermbox` public functions to communicate with `ExTermbox.Server`.
- **Event Processing:** Implemented logic in `ExTermbox.Server` to map raw NIF event data to `ExTermbox.Event` structs.
- **Integration Tests:** Updated existing tests to work with the `GenServer` API and removed obsolete Port/UDS tests.
- **Documentation:** Updated `README.md` and function documentation (`@doc`) to reflect the new NIF architecture, `GenServer` usage, and event handling mechanism.

### Removed

- Obsolete `ExTermbox.debug_crash/1` and `ExTermbox.debug_send_event/9` functions.
- Old `ExTermbox.NIF` wrapper module (calls are made directly to `:termbox2`).

### Fixed

- **NIF Loading:** Resolved NIF path loading issues by using a patched fork (`Hydepwns/termbox2-nif`) and ensuring submodules are included.
- **Missing NIF Bindings:** Added necessary NIF bindings (`tb_set_input_mode`, `tb_set_output_mode`, etc.) to the `termbox2-nif` fork.
- **Compiler Warnings:** Addressed various compiler warnings related to unused variables, aliases, and unreachable code.

### Known Issues / TODO

- **`get_cell/2` NIF Dependency:** The `ExTermbox.get_cell/2` function requires the `tb_get_cell(x, y)` NIF to be implemented in the `Hydepwns/termbox2-nif` fork to function correctly.
- **Example Tests:** Integration tests for examples (`test/integration/examples_test.exs`) could be enhanced (Low priority).
- **Upstream Dependency:** Relies on a fork of `termbox2-nif`. Ideally, these changes would be merged upstream or the fork published reliably.

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

## [1.0.0] - 2025-04-28

### Added

- Created `lib/ex_termbox/nif.ex` to handle NIF loading (using `@on_load`).
- Created `lib/ex_termbox/server.ex` implementing a `GenServer` to manage the termbox lifecycle (`tb_init`/`tb_shutdown`), handle API calls via NIF interaction, and perform event polling.
- Created `lib/ex_termbox/event.ex` defining the `ExTermbox.Event` struct for parsed events.

### Changed (API Refactoring)

- Refactored the `ExTermbox` module:
  - `ExTermbox.init/1` now starts the `ExTermbox.Server` GenServer.
  - `ExTermbox.shutdown/0` now stops the `ExTermbox.Server`.
  - Most public API functions (`present/0`, `clear/0`, `width/0`, `height/0`, `change_cell/5`, `set_cursor/2`, `print/5`, `select_input_mode/1`, `set_output_mode/1`, `set_clear_attributes/2`) now communicate with the `ExTermbox.Server` via `GenServer.call/cast` instead of requiring a process PID.
  - Event polling functions (`poll_event`, `peek_event`) removed; events are now automatically polled by the server and sent to the owner process as `{:termbox_event, %ExTermbox.Event{}}` messages (NIF event format and mapping require verification).
- `ExTermbox.Server` implements basic event polling using `NIF.tb_peek_event/1` and sends parsed events to the owner process (NIF event format and mapping require verification).
