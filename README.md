# Raxol Revived ExTermbox

[![Hex.pm](https://img.shields.io/hexpm/v/rrex_termbox.svg)](https://hex.pm/packages/rrex_termbox)
[![Hexdocs.pm](https://img.shields.io/badge/api-hexdocs-brightgreen.svg)](https://hexdocs.pm/rrex_termbox)

An Elixir library for interacting with the terminal via the [termbox2](https://github.com/termbox/termbox2) C library, a maintained fork of the original termbox.

**Starting with version 2.0.0, this library uses Elixir Native Implemented Functions (NIFs) provided by the [`termbox2`](https://hex.pm/packages/termbox2) Hex package (and its associated NIF bindings).** This replaces the previous Port/Unix Domain Socket architecture, leveraging a maintained C library and simplifying the build process.

For high-level, declarative terminal UIs in Elixir, see [raxol](https://github.com/Hydepwns/raxol) or its predecessor [Ratatouille](https://github.com/ndreynolds/ratatouille), which build on top of this library.

For the API Reference, see the `ExTermbox` module: [https://hexdocs.pm/rrex_termbox/ExTermbox.html](https://hexdocs.pm/rrex_termbox/ExTermbox.html).

## Getting Started

### Architecture (NIF Based)

**Note:** If you previously used versions prior to 2.0.0, be aware that the underlying communication mechanism has changed significantly from a Port/UDS system back to NIFs, leveraging the `termbox2` dependency. See the [Changelog](./CHANGELOG.md) for details.

`ExTermbox` now interacts directly with the `termbox2` C library through NIFs provided by the `termbox2` Hex dependency.

1. **Initialization:** `ExTermbox.init/1` starts a `GenServer` (`ExTermbox.Server`) which calls the `tb_init()` NIF function. This server manages the termbox state and handles API calls.
2. **API Calls:** Public functions in the `ExTermbox` module (e.g., `ExTermbox.print/5`, `ExTermbox.clear/0`, `ExTermbox.present/0`) communicate with the `ExTermbox.Server` via `GenServer` calls/casts. The server then invokes the corresponding `termbox2` NIF function (e.g., `tb_print`, `tb_clear`, `tb_present`).
3. **Event Handling:** The `ExTermbox.Server` periodically polls for terminal events (like key presses, mouse events, or resizes) using the `tb_peek_event()` NIF. When an event occurs, it's translated into an `ExTermbox.Event` struct and sent as a standard Elixir message (`{:termbox_event, event}`) to the process that originally called `ExTermbox.init/1` (the "owner" process).

The public API is exposed primarily through the `ExTermbox` module.

### Hello World

Let's go through a simple example.

Create an Elixir script (e.g., `hello.exs`) in any Mix project that includes `rrex_termbox` in its dependencies (see Installation below).

```elixir
# hello.exs
defmodule HelloWorld do
  use GenServer
  alias ExTermbox

  def start_link(_opts) do
    # Start our process that will own the termbox session
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Initialize ExTermbox, registering this GenServer process as the owner
    # The owner process will receive {:termbox_event, event} messages
    case ExTermbox.init(self()) do
      :ok ->
        IO.puts("ExTermbox initialized successfully.")
        # Send ourselves a message to trigger drawing the initial screen
        send(self(), :draw)
        {:ok, %{}} # Initial state for our GenServer

      {:error, reason} ->
        IO.inspect(reason, label: "Error initializing ExTermbox")
        {:stop, :init_failed}
    end
  end

  @impl true
  def handle_info(:draw, state) do
    # Clear the screen
    :ok = ExTermbox.clear()

    # Print "Hello, World!" at (0, 0) with default colors
    :ok = ExTermbox.print(0, 0, :default, :default, "Hello, World!")

    # Print "(Press <q> to quit)" at (0, 2)
    :ok = ExTermbox.print(0, 2, :default, :default, "(Press <q> to quit)")

    # Render the changes to the terminal
    :ok = ExTermbox.present()
    {:noreply, state}
  end

  # Handle events sent from ExTermbox.Server
  @impl true
  def handle_info({:termbox_event, %ExTermbox.Event{type: :key, key: :q}}, state) do
    IO.puts("Quit event received.")
    # Trigger shutdown before stopping
    ExTermbox.shutdown()
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:termbox_event, event}, state) do
    # Optional: Log other events
    # IO.inspect(event, label: "Received event")
    {:noreply, state}
  end

  # Handle other messages if needed
  @impl true
  def handle_info(msg, state) do
    # IO.inspect(msg, label: "Received other message")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    IO.puts("HelloWorld GenServer terminating: #{inspect(reason)}")
    # Ensure termbox is shut down if termination wasn't triggered by :q
    # (This might be redundant if ExTermbox.Server links/monitors)
    ExTermbox.shutdown()
    :ok
  end

  # Helper to run the example
  def run do
    # Ensure the app is started if running as a script
    {:ok, _} = Application.ensure_all_started(:rrex_termbox)

    {:ok, pid} = start_link([])
    # Keep the script alive until the GenServer terminates
    Process.monitor(pid)
    receive do
      {:DOWN, _, :process, ^pid, reason} ->
        IO.puts("HelloWorld process finished: #{inspect(reason)}")
    end
  end
end

HelloWorld.run()
```

In this example, we use a `GenServer` to manage the application's lifecycle and handle the asynchronous `{:termbox_event, ...}` messages.

Finally, run the example like this (assuming you have `rrex_termbox` added to a Mix project):

```bash
mix run hello.exs
```

You should see the text we rendered and be able to quit with 'q'.

## Installation

Add `rrex_termbox` as a dependency in your project's `mix.exs`.

**Important:** This library currently relies on a fork of the `termbox2` NIF wrapper to include necessary fixes and features. Point your dependency directly to the GitHub repository:

```elixir
def deps do
  [
    # {:rrex_termbox, "~> 2.0.0"}, # Use this once published to Hex
    {:rrex_termbox, git: "https://github.com/Hydepwns/rrex_termbox.git", tag: "v2.0.0-alpha.2"} # Or branch: "main"

    # The underlying NIF library (currently points to a fork)
    # rrex_termbox depends on this, so it's usually fetched automatically,
    # but explicitly listing it might be needed for overrides.
    # {:termbox2, github: "Hydepwns/termbox2-nif", tag: "0.1.1-hydepwns-fix1", submodules: true}
  ]
end
```

*(Note: Once `rrex_termbox` v2.0.0 (or later) is published on Hex.pm and the underlying `termbox2` dependency issues are resolved upstream or the fork is published, the dependency specification can likely be simplified back to `{:rrex_termbox, "~> 2.0.0"}`.)*

You will need standard C build tools (like `gcc` or `clang`, often part of `build-essential` or Xcode Command Line Tools) installed on your system for the `termbox2` NIF dependency to compile.

Mix should handle fetching the dependency and compiling the NIFs automatically when you run `mix deps.get` and `mix compile`.

If you encounter build issues, ensure your build tools are installed and check the `termbox2` dependency's documentation or repository for any specific requirements.

## NIF Precompilation and Auto-Download

Starting with version 2.0.4, `rrex_termbox` will automatically download the correct precompiled NIF binary for your platform from the latest GitHub Release if it is not already present in the `priv/` directory. This means:

- **No manual build is required** for supported platforms (Linux x86_64, macOS x86_64/aarch64, Windows x86_64).
- On first use, the library will fetch the appropriate binary and place it in the correct location.
- If the download fails (e.g., no network, unsupported platform, or missing asset), a clear error will be raised with troubleshooting instructions.
- If you are on an unsupported platform or want to build from source, you can still do so by following the instructions in the `termbox2` NIF dependency.

This workflow requires network access the first time you use the library on a new platform or after clearing the `priv/` directory.

### Dependencies

The auto-download feature uses [`httpoison`](https://hex.pm/packages/httpoison) and [`jason`](https://hex.pm/packages/jason) for HTTP requests and JSON parsing. These are included as dependencies in `mix.exs`.

## Distribution

Building standalone releases for applications using `rrex_termbox` (and its underlying NIF dependency) should work with standard Elixir **[Releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html)**. The build process compiles the NIFs into a shared object file (`.so` or `.dylib`) located in the `priv/` directory of the dependency (`termbox2`). Releases are designed to package these `priv/` artifacts correctly.

Ensure your release configuration properly includes the `rrex_termbox` and `termbox2` applications. Consult the Elixir Releases documentation for details.
