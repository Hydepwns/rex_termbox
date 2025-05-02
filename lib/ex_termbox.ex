# Define the registry module first
# defmodule ExTermbox.Registry do
#   use Elixir.Registry, keys: :unique, name: ExTermbox.Registry.Supervisor
# end

defmodule ExTermbox do
  require Logger
  # require ExTermbox.Constants # Alias is enough
  alias ExTermbox.Constants
  # Remove unused aliases
  # alias ExTermbox.Server # Add alias for the GenServer
  # alias ExTermbox.NIF # Add alias for NIF functions if needed directly (maybe not)

  # Define the registry
  # defmodule Registry, do: use(Elixir.Registry, keys: :unique, name: __MODULE__.Registry)

  # Define common type for pid() or registered name atom()
  @type pid_or_name :: pid() | atom()

  # Default atom name for local registration
  # Make it slightly more specific
  # @port_handler_key :ex_termbox_port_handler

  @moduledoc """
  Elixir bindings for the termbox2 library, providing a way to control the
  terminal and draw simple UIs using Erlang NIFs.

  This module provides the main user-facing API. It interacts with the termbox2
  NIF functions via the `ExTermbox.Server` GenServer, which must be running.

  ## Architecture

  `ExTermbox` relies on a `GenServer`, typically registered as `ExTermbox.Server`,
  to manage the lifecycle of the `termbox2` NIF library and handle asynchronous
  events. Most functions in this module are thin wrappers that send messages
  (calls or casts) to this server process.

  See `ExTermbox.Server` for implementation details.

  ## Usage

  1.  **Initialization:** Call `ExTermbox.init/1` to start the `ExTermbox.Server`.
      This calls `tb_init()` via the NIF and registers the calling process
      as the 'owner' to receive events.
  2.  **API Calls:** Use functions like `change_cell/5`, `clear/0`, `print/5`, etc.
      These functions communicate with the running `ExTermbox.Server`.
  3.  **Display:** Call `ExTermbox.present/0` to synchronize the internal back
      buffer with the terminal screen.
  4.  **Events:** The `ExTermbox.Server` automatically polls for terminal events
      (keyboard, mouse, resize) using `tb_peek_event()` via the NIF. Events are
      parsed into `%ExTermbox.Event{}` structs and sent as messages in the format
      `{:termbox_event, event}` to the owner process (the one that called `init/1`).
      You do not need to manually poll for events.
  5.  **Shutdown:** Call `ExTermbox.shutdown/0` when finished.
      This stops the `ExTermbox.Server` gracefully, which in turn calls
      `tb_shutdown()` via the NIF.

  ## Event Handling

  Events are delivered automatically as messages in the format `{:termbox_event, %ExTermbox.Event{}}`
  to the process that called `init/1`. You should handle these messages in your
  process's `handle_info/2` callback (if it's a GenServer or similar OTP process).

  Example (`handle_info` in the owner process):

  ```elixir
  def handle_info({:termbox_event, %ExTermbox.Event{type: :key, key: :q}}, state) do
    IO.puts("Quit key pressed!")
    # Initiate shutdown sequence
    ExTermbox.shutdown()
    {:stop, :normal, state}
  end

  def handle_info({:termbox_event, event}, state) do
    IO.inspect(event, label: "Received Termbox Event")
    # Handle other events (resize, mouse, other keys)
    {:noreply, state}
  end
  ```
  """

  # Registered name for the GenServer
  @server_name ExTermbox.Server

  @doc """
  Initializes the termbox library by starting the `ExTermbox.Server` GenServer.

  This function attempts to start and link an `ExTermbox.Server` process.
  The server process, upon its own initialization, will call the underlying
  `termbox2` NIF function `tb_init()`.

  The calling process is registered as the "owner" of the termbox session and
  will receive `{:termbox_event, %ExTermbox.Event{}}` messages.

  Returns `{:ok, server_name}` on success, where `server_name` is the atom used
  to register the GenServer (defaults to `ExTermbox.Server`). Returns `{:error, reason}`
  if the server cannot be started or if `tb_init()` fails within the server.

  If the server is already running under the specified name, it logs a warning
  and returns `{:ok, server_name}` without attempting to start a new one.

  Options:
    - `:name` (atom): The registered name for the `ExTermbox.Server` GenServer.
      Defaults to `#{inspect(@server_name)}`.
    - `:owner` (pid): The PID to receive termbox events. Defaults to `self()`.
      This is typically not overridden directly, as `init/1` sets it.
    - `:poll_interval_ms` (pos_integer): The interval in milliseconds for polling
      terminal events via `tb_peek_event`. Defaults to `10`.

  All options are passed down to `ExTermbox.Server.start_link/1`.
  """
  @spec init(keyword) :: {:ok, atom()} | {:error, any}
  def init(opts \\ []) do
    # Ensure the owner is set to the caller
    init_opts = Keyword.put_new(opts, :owner, self())
    # Use the default server name unless overridden
    server_name = Keyword.get(opts, :name, @server_name)

    # Check if the server is already running
    case GenServer.whereis(server_name) do
      pid when is_pid(pid) ->
        # Already started, log and return ok
        Logger.warning("ExTermbox.Server (#{inspect(server_name)}) already started with PID: #{inspect(pid)}. Returning :ok.")
        {:ok, server_name}

      nil ->
        # Not running, attempt to start
        # Add the name option for start_link
        start_opts = Keyword.put(init_opts, :name, server_name)

        Logger.debug(
          "ExTermbox.init starting Server (#{inspect(server_name)}) with opts: #{inspect(start_opts)}"
        )

        case ExTermbox.Server.start_link(start_opts) do
          {:ok, _pid} ->
            # Return the registered name used
            {:ok, server_name}

          # The :already_started case is now handled by the whereis check above.
          # We only need to handle other errors.
          {:error, reason} ->
            Logger.error("ExTermbox.Server start_link failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Shuts down the termbox library by stopping the `ExTermbox.Server` GenServer.

  This function finds the `ExTermbox.Server` process (using the provided or
  default name) and requests it to stop gracefully (using `:shutdown`).

  The server's `terminate/2` callback is responsible for calling the `termbox2`
  NIF function `tb_shutdown()` to restore the terminal state.

  Returns `:ok` if the stop request was sent or if the server was not running.
  Returns `{:error, reason}` if finding the server process fails unexpectedly.

  Arguments:
    - `server_name`: The registered name of the server to stop.
      Defaults to `#{inspect(@server_name)}`.
  """
  @spec shutdown(atom) :: :ok | {:error, :unexpected_registry_value}
  def shutdown(server_name \\ @server_name) do
    case GenServer.whereis(server_name) do
      nil ->
        Logger.warning(
          "Attempted to shutdown ExTermbox.Server (#{inspect(server_name)}), but it was not running."
        )
        # It's already stopped or never started, consider this success.
        :ok

      pid when is_pid(pid) ->
        Logger.debug("Stopping ExTermbox.Server (#{inspect(server_name)}) with PID: #{inspect(pid)}")
        # Use :shutdown reason for graceful termination
        GenServer.stop(pid, :shutdown)
        # GenServer.stop is synchronous for the exit signal *sending*,
        # but doesn't wait for termination. Return :ok as the request was sent.
        :ok

      other ->
        # This case should ideally not happen with whereis/1
        Logger.error(
          "Found unexpected value for server name #{inspect(server_name)}: #{inspect(other)}. Cannot stop."
        )
        {:error, :unexpected_registry_value}
    end
  end

  @doc """
  Returns the width of the terminal by querying the `ExTermbox.Server`.

  The server retrieves this information via the `termbox2` NIF function `tb_width()`.

  Arguments:
    - `server`: The registered name or PID of the server (defaults to `#{@server_name}`).
  """
  @spec width(atom | pid) :: {:ok, non_neg_integer} | {:error, any}
  def width(server \\ @server_name) do
    GenServer.call(server, :width)
  end

  @doc """
  Returns the height of the terminal by querying the `ExTermbox.Server`.

  The server retrieves this information via the `termbox2` NIF function `tb_height()`.

  Arguments:
    - `server`: The registered name or PID of the server (defaults to `#{@server_name}`).
  """
  @spec height(atom | pid) :: {:ok, non_neg_integer} | {:error, any}
  def height(server \\ @server_name) do
    GenServer.call(server, :height)
  end

  @doc ~S"""
  Retrieves the character, foreground, and background attributes of a specific cell
  by querying the `ExTermbox.Server`.

  **Note:** This function is not currently implemented in v2.0.0. The underlying
  `tb_get_cell/2` function is not available in the current termbox2_nif version.
  Calls will return `{:error, {:not_implemented, "..."}}`.
  
  This feature may be added in a future version when the NIF library is updated.

  Returns `{:ok, {char_codepoint, fg_attribute, bg_attribute}}` on success,
  or `{:error, reason}` on failure.

  Arguments:
    - `x`: The zero-based column index.
    - `y`: The zero-based row index.
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).
  """
  @spec get_cell(integer, integer, atom | pid) :: {:ok, {integer, integer, integer}} | {:error, any}
  def get_cell(x, y, server \\ @server_name) when is_integer(x) and is_integer(y) do
    GenServer.call(server, {:get_cell, x, y})
  end

  @doc ~S"""
  Selects the input mode by sending a request to the `ExTermbox.Server`.

  The server validates the mode atom against `ExTermbox.Constants.input_mode/1`
  and then calls the `termbox2` NIF function `tb_set_input_mode()`.

  Arguments:
    - `mode`: An input mode atom defined in `ExTermbox.Constants` (e.g., `:esc`, `:alt`, `:mouse`).
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok` on success, `{:error, :invalid_input_mode}` if the mode atom is
  unrecognized, or `{:error, reason}` for other GenServer call errors.
  """
  @spec select_input_mode(atom, atom | pid) :: :ok | {:error, :invalid_input_mode | any()}
  def select_input_mode(mode, server \\ @server_name) when is_atom(mode) do
    try do
      mode_int = Constants.input_mode(mode)
      GenServer.call(server, {:set_input_mode, mode_int})
    catch
      :error, {:key_not_found, _, _} -> {:error, :invalid_input_mode}
      kind, reason -> {:error, {kind, reason}} # Catch GenServer call errors etc.
    end
  end

  @doc ~S"""
  Clears the internal back buffer by sending a request to the `ExTermbox.Server`.

  The server calls the `termbox2` NIF function `tb_clear()`.
  This does not immediately affect the visible terminal; `present/1` must be called
  to synchronize.

  Arguments:
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok` on success or `{:error, reason}` if the GenServer call fails.
  """
  @spec clear(atom | pid) :: :ok | {:error, any}
  def clear(server \\ @server_name) do
    # Clear is usually fast, cast might be okay, but call ensures completion.
    GenServer.call(server, :clear)
  end

  @doc ~S"""
  Synchronizes the internal back buffer with the terminal screen by sending a
  request to the `ExTermbox.Server`.

  The server calls the `termbox2` NIF function `tb_present()`.

  Arguments:
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok` on success or `{:error, reason}` if the GenServer call fails.
  """
  @spec present(atom | pid) :: :ok | {:error, any}
  def present(server \\ @server_name) do
    # Present must complete before next draw cycle, so use call.
    GenServer.call(server, :present)
  end

  @doc ~S"""
  Sets the cursor position by sending a request to the `ExTermbox.Server`.

  The server calls the `termbox2` NIF function `tb_set_cursor()`.

  Use `x = -1` and `y = -1` (or the default arguments) to hide the cursor.
  See `ExTermbox.Constants.hide_cursor/0`.

  Arguments:
    - `x`: The zero-based column index (-1 to hide).
    - `y`: The zero-based row index (-1 to hide).
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok`. This function uses `GenServer.cast`, so errors during the NIF call
  will not be reported back directly but may be logged by the server.
  """
  @spec set_cursor(integer, integer, atom | pid) :: :ok
  def set_cursor(x \\ Constants.hide_cursor(), y \\ Constants.hide_cursor(), server \\ @server_name)
      when is_integer(x) and is_integer(y) do
    # Setting cursor is quick, cast is likely fine.
    GenServer.cast(server, {:set_cursor, x, y})
  end

  @doc ~S"""
  Changes the character, foreground, and background attributes of a specific cell
  in the internal back buffer by sending a request to the `ExTermbox.Server`.

  The server calls the `termbox2` NIF function `tb_set_cell()`.
  This does not immediately affect the visible terminal; `present/1` must be called
  to synchronize.

  Arguments:
    - `x`: The zero-based column index.
    - `y`: The zero-based row index.
    - `char`: The character to place in the cell. Can be:
        - An integer codepoint (e.g., `?a`).
        - A single-character string (e.g., `"a"`).
        - A single-codepoint UTF-8 string (e.g., `"€"`).
    - `fg`: The foreground attribute (an integer constant from `ExTermbox.Constants`).
      Combine colors (e.g., `Constants.color(:red)`) with attributes
      (e.g., `Constants.attribute(:bold)`) using bitwise OR (`Bitwise.bor/2`).
    - `bg`: The background attribute (an integer constant from `ExTermbox.Constants`).
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok` if the arguments are valid and the request is sent.
  Returns `{:error, :invalid_char}` if the `char` argument is not a valid single
  character representation.

  This function uses `GenServer.cast`, so errors during the NIF call itself
  will not be reported back directly but may be logged by the server.
  """
  @spec change_cell(integer, integer, char | String.t(), integer, integer, atom | pid) :: :ok | {:error, any}
  def change_cell(x, y, char, fg, bg, server \\ @server_name)
      when is_integer(x) and is_integer(y) and is_integer(fg) and is_integer(bg) do
    # Allow single char string or integer codepoint
    case p_char_to_codepoint(char) do
      {:ok, codepoint} ->
        # Changing a cell is usually part of a batch, cast is appropriate.
        GenServer.cast(server, {:change_cell, x, y, codepoint, fg, bg})
      :error ->
        {:error, :invalid_char}
    end
  end

  # Helper to convert various char inputs to a codepoint
  defp p_char_to_codepoint(char) when is_integer(char) do
    {:ok, char}
  end

  defp p_char_to_codepoint(char) when is_binary(char) do
    case :unicode.characters_to_list(char) do
      [codepoint] -> {:ok, codepoint}
      _ -> :error # Not a single codepoint string
    end
  end

  defp p_char_to_codepoint(_other) do
    :error
  end

  @doc ~S"""
  A convenience function to print a string at a given position with specified attributes.

  This function iterates through the string's characters and calls `change_cell/6`
  for each one, sending multiple requests to the `ExTermbox.Server`.

  Note: This function assumes a left-to-right character display and does not handle
  line wrapping or terminal boundaries explicitly. Characters printed beyond the
  terminal width might be ignored by the underlying `termbox2` library.

  Arguments:
    - `x`: The starting zero-based column index.
    - `y`: The zero-based row index.
    - `fg`: The foreground attribute (integer constant from `ExTermbox.Constants`).
    - `bg`: The background attribute (integer constant from `ExTermbox.Constants`).
    - `str`: The string to print.
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok`. Like `change_cell/6`, this uses `GenServer.cast`, so errors during
  individual NIF calls are not reported directly.
  """
  @spec print(integer, integer, integer, integer, String.t(), atom | pid) :: :ok
  def print(x, y, fg, bg, str, server \\ @server_name)
      when is_integer(x) and is_integer(y) and is_integer(fg) and is_integer(bg) and is_binary(str) do
    # Iterate through codepoints and call change_cell for each
    # Start pipe with the data
    str
    |> :unicode.characters_to_list()
    |> Enum.with_index()
    |> Enum.each(fn {codepoint, index} ->
      # We ignore the return value of change_cell (which is just :ok from cast)
      change_cell(x + index, y, codepoint, fg, bg, server)
    end)
    # Since casts are async, we just return :ok immediately assuming they will eventually succeed.
    :ok
  end

  # Event polling functions (poll_event/peek_event) are removed as the
  # GenServer handles event polling automatically and pushes events to the owner.

  @doc ~S"""
  Sets the output mode by sending a request to the `ExTermbox.Server`.

  The server validates the mode atom against `ExTermbox.Constants.output_mode/1`
  and then calls the `termbox2` NIF function `tb_set_output_mode()`.

  Arguments:
    - `mode`: An output mode atom defined in `ExTermbox.Constants` (e.g., `:normal`, `:grayscale`, `:xterm256`).
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok` on success, `{:error, :invalid_output_mode}` if the mode atom is
  unrecognized, or `{:error, reason}` for other GenServer call errors.
  """
  @spec set_output_mode(atom, atom | pid) :: :ok | {:error, :invalid_output_mode | any()}
  def set_output_mode(mode, server \\ @server_name) when is_atom(mode) do
    try do
      mode_int = Constants.output_mode(mode)
      GenServer.call(server, {:set_output_mode, mode_int})
    catch
      :error, {:key_not_found, _, _} -> {:error, :invalid_output_mode}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc ~S"""
  Sets the clear attributes (foreground and background) used by `clear/1`
  by sending a request to the `ExTermbox.Server`.

  The server validates the attributes and calls the `termbox2` NIF function
  `tb_set_clear_attrs()`.

  Arguments:
    - `fg`: The foreground attribute (an integer constant from `ExTermbox.Constants`).
    - `bg`: The background attribute (an integer constant from `ExTermbox.Constants`).
    - `server`: The registered name or PID of the server (defaults to `#{inspect(@server_name)}`).

  Returns `:ok` on success, or `{:error, reason}` if the GenServer call fails.
  """
  @spec set_clear_attributes(integer, integer, atom | pid) :: :ok | {:error, any}
  def set_clear_attributes(fg, bg, server \\ @server_name) when is_integer(fg) and is_integer(bg) do
    try do
      # Assuming Constants.color/1 handles colors and attributes
      fg_int = Constants.color(fg)
      bg_int = Constants.color(bg)
      GenServer.call(server, {:set_clear_attributes, fg_int, bg_int})
    catch
      :error, {:key_not_found, key, _} -> {:error, {:invalid_color_or_attribute, key}}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc """
  [Debug] Causes the C helper process to exit immediately.
  FOR TESTING ONLY.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec debug_crash(pid | atom) :: :ok | {:error, any}
  def debug_crash(pid_or_name) do
    command_key = :debug_crash
    command_string = "DEBUG_CRASH\n" # Simple command, no args
    # We might not get a reply if the process crashes before replying.
    # Consider using cast or handling call timeout/exit.
    # Let's try call first, and the test can handle the potential `:noproc` error.
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, ExTermbox.PortHandler) # Default name
    handler_opts = Keyword.put(opts, :owner, self())
    Logger.debug("ExTermbox.init starting PortHandler with name: #{inspect(name)}, opts: #{inspect(handler_opts)}")
    GenServer.start_link(ExTermbox.PortHandler, handler_opts, name: name)
  end

  # -- Private Helpers --

  # Helper to call the GenServer, requires pid or name
  # Corrected if/try/catch/else structure
  defp call_genserver(pid_or_name, request, timeout \\ 5000) do
    # Use the provided pid_or_name directly, assume it's either the registered name or a PID
    # No need for Process.whereis here if we trust the caller or use the registered name.
    # target = Process.whereis(pid_or_name) || pid_or_name # Original logic
    GenServer.call(pid_or_name, request, timeout)
  end

  # REMOVED redundant call_handler/2 helper
  # defp call_handler(pid_or_name, command_key) do
  #   command_string = ExTermbox.Protocol.format_command(command_key)
  #   # Call the genserver directly with the formatted command string
  #   call_genserver(pid_or_name, {:command, command_key, command_string})
  # end
end
