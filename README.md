# Raxol Revived ExTermbox

[![Hex.pm](https://img.shields.io/hexpm/v/rrex_termbox.svg)](https://hex.pm/packages/rrex_termbox)
[![Hexdocs.pm](https://img.shields.io/badge/api-hexdocs-brightgreen.svg)](https://hexdocs.pm/rrex_termbox)

An Elixir library for interacting with the terminal via the [termbox2](https://github.com/termbox/termbox2) C library, a maintained fork of the original termbox.

For high-level, declarative terminal UIs in Elixir, see [raxol](https://github.com/Hydepwns/raxol).

For the API Reference, see the `ExTermbox` module: [https://hexdocs.pm/rrex_termbox/ExTermbox.html](https://hexdocs.pm/rrex_termbox/ExTermbox.html).

## Getting Started

### Architecture (NIF Based)

`ExTermbox` now interacts directly with the `termbox2` C library through NIFs provided by the `termbox2` Hex dependency.

**Note:** If you previously used versions prior to 2.0.0, be aware that the underlying communication mechanism has changed significantly from a Port/UDS system back to NIFs, leveraging the `termbox2` dependency. See the [Changelog](./CHANGELOG.md) for details.

1. **Initialization:** `ExTermbox.init/1` starts a `GenServer` (`ExTermbox.Server`) which calls the `tb_init()` NIF function. This server manages the termbox state and handles API calls.
2. **API Calls:** Public functions in the `ExTermbox` module (e.g., `ExTermbox.print/5`, `ExTermbox.clear/0`, `ExTermbox.present/0`) communicate with the `ExTermbox.Server` via `GenServer` calls/casts. The server then invokes the corresponding `termbox2` NIF function (e.g., `tb_print`, `tb_clear`, `tb_present`).
3. **Event Handling:** The `ExTermbox.Server` periodically polls for terminal events (like key presses, mouse events, or resizes) using the `tb_peek_event()` NIF. When an event occurs, it's translated into an `ExTermbox.Event` struct and sent as a standard Elixir message (`{:termbox_event, event}`) to the process that originally called `ExTermbox.init/1` (the "owner" process). The public API is exposed primarily through the `ExTermbox` module.
4. **Shutdown:** `ExTermbox.shutdown/0` stops the `ExTermbox.Server` and calls the `tb_shutdown()` NIF function.

Finally, run the example like this (assuming you have `rrex_termbox` added to a Mix project):

```bash
mix run hello.exs
```

You should see the text we rendered and be able to quit with 'q'.

## Installation

Add `rrex_termbox` as a dependency in your project's `mix.exs`.

```elixir
def deps do
  [
    {:rrex_termbox, "~> 2.0.6"}
  ]
end
```

Mix should handle fetching the dependency and compiling the NIFs automatically when you run `mix deps.get` and `mix compile`.

## NIF Auto-Download (No Manual Build Needed!)

**Starting with version 2.0.4, `rrex_termbox` will automatically download the correct precompiled NIF binary for your platform (macOS, Linux, Windows) if it is not already present.**

- **No manual build is required** for most users and CI environments.
- On first use, the library fetches the appropriate binary and places it in the correct location.
- If the download fails (e.g., no network, unsupported platform, or missing asset), a clear error is raised with troubleshooting instructions.
- Manual build is only needed for unsupported platforms or advanced development.
- This makes onboarding contributors and running in CI seamless—just `mix deps.get && mix test`!

## Building the NIF

- If you are on an unsupported platform, or want to build from source, you can still do so:

```bash
mix compile.nif
```

This will compile the C sources in `c_src/` and place the resulting binary in the `priv/` directory with the correct name for your platform. You only need to do this after changing the NIF source or switching platforms.

To clean up all NIF binaries and build artifacts, run:

```bash
mix clean.nif
```

## Distribution

Building standalone releases for applications using `rrex_termbox` (and its underlying NIF dependency) should work with standard Elixir **[Releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html)**. The build process compiles the NIFs into a shared object file (`.so` or `.dylib`) located in the `priv/` directory of the dependency (`termbox2`). Releases are designed to package these `priv/` artifacts correctly.

Ensure your release configuration properly includes the `rrex_termbox` and `termbox2` applications. Consult the Elixir Releases documentation for details.
