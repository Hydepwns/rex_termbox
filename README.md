# Raxol Revived ExTermbox

[![Hex.pm](https://img.shields.io/hexpm/v/rrex_termbox.svg)](https://hex.pm/packages/rrex_termbox)
[![Hexdocs.pm](https://img.shields.io/badge/api-hexdocs-brightgreen.svg)](https://hexdocs.pm/rrex_termbox)

An Elixir library for interacting with the terminal via the [termbox](https://github.com/nsf/termbox) C library.

This library manages a separate C helper process (`termbox_port`) and communicates with it using an Elixir Port for initialization and Unix Domain Sockets (UDS) for subsequent commands and events. This provides a more robust alternative to NIF-based approaches.

For high-level, declarative terminal UIs in Elixir, see [raxol](https://github.com/Hydepwns/raxol) or it's predecessor [Ratatouille](https://github.com/ndreynolds/ratatouille). It builds on top of
this library and the termbox API to provide an HTML-like DSL for defining views.

For the API Reference, see the `ExTermbox` module: [https://hexdocs.pm/rrex_termbox/ExTermbox.html](https://hexdocs.pm/rrex_termbox/ExTermbox.html).

## Getting Started

### Architecture

ExTermbox starts and manages a C helper program (`termbox_port`). Communication happens as follows:

1. **Initialization:** An Elixir Port is used briefly to exchange the path for a Unix Domain Socket (UDS).
2. **Runtime:** All subsequent commands (like printing, setting cursor, changing cells) and events (like key presses, resizes) are sent over the UDS connection using a simple text-based protocol.

The public API is exposed primarily through the `ExTermbox` module.

### Hello World

Let's go through a simple example.
To follow along, clone this repo and save the code below as an `.exs` file (e.g., `hello.exs`).

This repository makes use of [Git submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules), so make sure you include them in your clone. In recent versions of git, this can be accomplished by including the `--recursive` flag, e.g.

```bash
# Make sure to clone *this* repository recursively to include submodules
git clone --recursive https://github.com/Hydepwns/rrex_termbox.git
```

When the clone is complete, the `c_src/termbox/` directory should have files in it.

You can also create an
Elixir script in any Mix project with `rrex_termbox` in the dependencies list.
Later, we'll run the example with `mix run <file>`.

```elixir
# hello.exs
defmodule HelloWorld do
  alias ExTermbox

  def run do
    # Start ExTermbox, registering the current process to receive events
    case ExTermbox.init(self()) do
      :ok ->
        IO.puts("ExTermbox initialized successfully.")
        # Clear the screen
        :ok = ExTermbox.clear()

        # Print "Hello, World!" at (0, 0) with default colors
        :ok = ExTermbox.print(0, 0, :default, :default, "Hello, World!")

        # Print "(Press <q> to quit)" at (0, 2)
        :ok = ExTermbox.print(0, 2, :default, :default, "(Press <q> to quit)")

        # Render the changes to the terminal
        :ok = ExTermbox.present()

        # Wait for the 'q' key event
        wait_for_quit()

        # Shut down ExTermbox
        :ok = ExTermbox.shutdown()
        IO.puts("ExTermbox shut down.")

      {:error, reason} ->
        IO.inspect(reason, label: "Error initializing ExTermbox")
    end
  end

  defp wait_for_quit do
    receive do
      # Events are sent as messages to the registered process
      {:termbox_event, %{type: :key, key: :q}} ->
        :quit
      {:termbox_event, event} ->
        # IO.inspect(event, label: "Received event") # Uncomment to see other events
        wait_for_quit() # Wait for the next event
      _other_message ->
        # IO.inspect(other_message, label: "Received other message")
        wait_for_quit() # Wait for the next event
    after
      10_000 -> IO.puts("Timeout waiting for 'q' key.") # Add a timeout for safety
    end
  end
end

HelloWorld.run()

```

In a real application, you'll likely want to integrate `ExTermbox` into an OTP application with a proper supervisor.

The `ExTermbox.print/5` function provides a simple way to display strings. For more control over individual cells (characters, foreground/background colors, attributes), use `ExTermbox.change_cell/5`. The `ExTermbox.width/0` and `ExTermbox.height/0` functions can be used to get the terminal dimensions.

Finally, run the example like this:

```bash
mix run hello.exs
```

You should see the text we rendered and be able to quit with 'q'.

## Python Build Compatibility (Python 3.12+)

The version of the `termbox` C library bundled with `:rrex_termbox` uses an older version of the `waf` build system. This version of `waf` contained code (`import imp`) that is incompatible with Python 3.12 and newer, causing the C helper compilation to fail if a modern Python version is your system default.

This fork includes a small patch directly within the bundled `waf` scripts (`c_src/termbox/.waf3-2.0.14-e67604cd8962dbdaf7c93e0d7470ef5b/waflib/Context.py`) to replace the incompatible code with its modern equivalent (`importlib`).

With this patch, `:rrex_termbox` should compile successfully using Python 3.12+ without requiring manual intervention or downgrading Python.

If you encounter build issues related to Python or `waf`, please ensure you are using a version of this library that includes this fix.

## Installation

Add `:rrex_termbox` as a dependency in your project's `mix.exs`:

```elixir
def deps do
  [
    {:rrex_termbox, "~> 1.1.0"}
  ]
end
```

The Hex package bundles a compatible version of termbox. You will need standard C build tools (like `gcc` or `clang`, often part of `build-essential` or Xcode Command Line Tools) installed on your system.

Mix compile hooks automatically build the `termbox_port` C helper executable needed by the library. This should happen the first time you build :rrex_termbox (e.g., via `mix deps.get` followed by `mix deps.compile` or simply `mix compile`).

The build has been tested on macOS and some Linux distributions. Please open an issue if you encounter build problems.

### Using the Source Directly

To try out the master branch, first clone the repo:

```bash
# Make sure to clone *this* repository recursively to include submodules
git clone --recurse-submodules <your-fork-url>
cd rrex_termbox # Assuming the directory name matches the repo
```

The `--recurse-submodules` flag (`--recursive` before Git 2.13) is necessary in
order to additionally clone the termbox source code, which is required to
build the C helper program.

Next, fetch the deps:

```
mix deps.get
```

Finally, try out the included event viewer application:

```
mix run examples/event_viewer.exs
```

If you see the application drawn and can trigger events, you're good to go. Use
'q' to quit the examples.

## Distribution

Building a standalone executable for applications using `:rrex_termbox` requires some special consideration due to the included C helper program (`termbox_port`) which needs to be packaged alongside your Elixir application.

Standard Elixir tools like `escript` are **not** suitable because they do not correctly package the necessary helper executable located in the `priv/` directory after compilation.

The recommended approach for creating distributable releases is to use **[Distillery](https://github.com/bitwalker/distillery)** or the built-in Elixir **[Releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html)**. These tools are designed to handle external programs and assets correctly. They will package your application, the Erlang Runtime System (ERTS), and the compiled `termbox_port` helper into a self-contained bundle.

Consult the documentation for Distillery or Elixir Releases for specific instructions on configuring your project for release builds, ensuring the `priv/termbox_port` executable is included in the release package.
