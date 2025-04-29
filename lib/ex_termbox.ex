# Define the registry module first
# defmodule ExTermbox.Registry do
#   use Elixir.Registry, keys: :unique, name: ExTermbox.Registry.Supervisor
# end

defmodule ExTermbox do
  require Logger

  # Define the registry
  # defmodule Registry, do: use(Elixir.Registry, keys: :unique, name: __MODULE__.Registry)

  # Default atom name for local registration
  # Make it slightly more specific
  @port_handler_key :ex_termbox_port_handler
  @default_timeout 5000

  @moduledoc """
  Elixir bindings for the termbox library, providing a way to control the
  terminal and draw simple UIs.

  This module provides the main user-facing API. It interacts with a C process
  via an Elixir Port managed by the `ExTermbox.PortHandler` GenServer.

  ## Usage

  1.  **Initialization:** Call `ExTermbox.init()` to start the necessary processes.
      This must be called before any other functions.
  2.  **Drawing:** Use functions like `change_cell/5`, `clear/0`, etc., to modify
      the terminal's back buffer.
  3.  **Display:** Call `ExTermbox.present/0` to flush the back buffer to the
      terminal screen.
  4.  **Events:** Call `ExTermbox.poll_event/0` to wait for user input or resize
      events. These will be sent as messages to the process that called `init/0`.
  5.  **Shutdown:** Call `ExTermbox.shutdown()` when finished to clean up.

  ## Event Handling

  Events are delivered as messages in the format `{:termbox_event, event_map}`
  to the process that called `init/0`. See `ExTermbox.PortHandler` for details
  on the event map structure. You typically need to call `poll_event/0` again
  after receiving an event to wait for the next one.

  Example (`handle_info` in the process that called `init/0`):

  ```elixir
  def handle_info({:termbox_event, event}, state) do
    IO.inspect(event, label: "Received Termbox Event")
    # Request next event
    ExTermbox.poll_event()
    {:noreply, state}
  end
  ```
  """

  @doc """
  Initializes the termbox library.

  Starts the PortHandler GenServer and sends the `init` command to the C port.
  Returns `{:ok, pid}` on success, where `pid` is the PortHandler process ID,
  or `{:error, reason}` on failure.

  Options:
    - `name`: Registers the GenServer under a specific name. Defaults to `#{@port_handler_key}`.
  """
  @spec init(keyword) :: {:ok, pid} | {:error, any}
  def init(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())
    name_opt = Keyword.take(opts, [:name])
    # Use default name if not provided
    name_to_use = Keyword.get(opts, :name, @port_handler_key)
    # Ensure name is passed
    handler_opts = Keyword.merge(name_opt, owner: self(), name: name_to_use)

    Logger.debug(
      "ExTermbox.init called, starting PortHandler with opts: #{inspect(handler_opts)}"
    )

    # Simply start the PortHandler. It handles its own internal init now.
    case ExTermbox.PortHandler.start_link(handler_opts) do
      {:ok, pid} ->
        Logger.debug(
          "PortHandler start_link successful. PID: #{inspect(pid)}, Name: #{inspect(name_to_use)}."
        )

        {:ok, pid}

      {:error, reason} = error_reply ->
        Logger.error("PortHandler start_link failed: #{inspect(reason)}")
        # Return the original start_link error
        error_reply
    end
  end

  @doc """
  Shuts down the termbox library and stops the PortHandler GenServer.

  Finds the GenServer using the default name `#{@port_handler_key}`.
  """
  @spec shutdown() :: :ok | {:error, any()}
  def shutdown() do
    # Find the process by name and call it
    case GenServer.whereis(@port_handler_key) do
      nil ->
        {:error, :not_running}

      pid ->
        GenServer.call(pid, :request_port_close)
    end
  end

  @doc """
  Returns the width of the terminal.

  Finds the GenServer using the default name `#{@port_handler_key}`.
  """
  @spec width() :: {:ok, integer} | {:error, any()}
  def width() do
    # Format using Protocol module
    command_str = ExTermbox.Protocol.format_width_command()
    # Identify the command by atom/tuple for pending_call matching
    command_key = :width
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Returns the height of the terminal.

  Finds the GenServer using the default name `#{@port_handler_key}`.
  """
  @spec height() :: {:ok, integer} | {:error, any()}
  def height() do
    # Format using Protocol module
    command_str = ExTermbox.Protocol.format_height_command()
    # Identify the command by atom/tuple for pending_call matching
    command_key = :height
    call_genserver({:command, command_key, command_str})
  end

  # --- Add other functions like clear, present, change_cell, poll_event here ---

  @doc """
  Clears the terminal buffer using the default colors.

  Finds the GenServer using the default name `#{@port_handler_key}`.
  """
  @spec clear() :: :ok | {:error, any()}
  def clear() do
    # Format using Protocol module
    command_str = ExTermbox.Protocol.format_clear_command()
    # Identify the command by atom/tuple for pending_call matching
    command_key = :clear
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Changes the character, foreground, and background attributes of a specific cell.

  Finds the GenServer using the default name `#{@port_handler_key}`.

  Arguments:
    - `x`: The zero-based column index.
    - `y`: The zero-based row index.
    - `char`: The character (as a single-char string or integer codepoint).
    - `fg`: The foreground attribute (e.g., `ExTermbox.Const.Color.RED`).
    - `bg`: The background attribute (e.g., `ExTermbox.Const.Attribute.BOLD`).
  """
  def change_cell(x, y, char, fg, bg)
      when is_integer(x) and is_integer(y) and is_integer(fg) and is_integer(bg) do
    codepoint =
      if is_integer(char),
        do: char,
        else: String.to_charlist(char) |> List.first()

    # Format using Protocol module
    command_str = ExTermbox.Protocol.format_change_cell_command(x, y, codepoint, fg, bg)
    # Identify the command by atom/tuple for pending_call matching
    command_key = :change_cell

    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Prints a string at the specified position with given attributes.

  Finds the GenServer using the default name `#{@port_handler_key}`.

  Arguments:
    - `x`: The zero-based column index for the start of the string.
    - `y`: The zero-based row index for the start of the string.
    - `fg`: The foreground attribute (e.g., `ExTermbox.Const.Color.RED`).
    - `bg`: The background attribute (e.g., `ExTermbox.Const.Attribute.BOLD`).
    - `string`: The string to print.
  """
  @spec print(integer, integer, integer, integer, String.t()) :: :ok | {:error, any()}
  def print(x, y, fg, bg, string)
      when is_integer(x) and is_integer(y) and is_integer(fg) and is_integer(bg) and is_binary(string) do
    # Ensure no newlines in the string itself, as it breaks the protocol
    safe_string = string |> String.replace("\n", "") |> String.replace("\r", "")
    # Format using Protocol module
    command_str = ExTermbox.Protocol.format_print_command(x, y, fg, bg, safe_string)
    # Identify the command by atom/tuple for pending_call matching
    command_key = {:print, x, y, fg, bg, safe_string}
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Presents the back buffer to the terminal.

  Finds the GenServer using the default name `#{@port_handler_key}`.
  """
  @spec present() :: :ok | {:error, any()}
  def present() do
    # Format using Protocol module
    command_str = ExTermbox.Protocol.format_present_command()
    # Identify the command by atom/tuple for pending_call matching
    command_key = :present
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Triggers the underlying termbox C process to start polling for the next event.

  Finds the GenServer using the default name `#{@port_handler_key}`.
  This sends the `poll_event` command asynchronously to the C port, which will
  then block internally using `tb_poll_event` until an event occurs.
  Use `wait_event/1` after calling this function to receive the actual event message.
  Returns `:ok` or `{:error, reason}`.
  """
  def trigger_poll_event() do
    # Use the default atom name for lookup
    case GenServer.whereis(@port_handler_key) do
      nil ->
        {:error, :not_running}

      pid ->
        # Send the command to the PortHandler, don't wait for GenServer reply here,
        # PortHandler replies :ok immediately.
        GenServer.call(pid, :trigger_poll_event)
    end
  end

  @doc """
  Waits for a termbox event message to be received.

  This function should typically be called after `trigger_poll_event/0`.
  It blocks the calling process until a `{:termbox_event, event_map}` message
  is received or the specified timeout occurs.

  The event message is sent by the `PortHandler` to the process that
  called `init/1` (the owner process). Ensure this function is called
  from the owner process or a process that can receive messages directed
  to the owner.

  ## Arguments

    * `timeout`: The maximum time in milliseconds to wait for an event.
      Defaults to `:infinity`.

  ## Return Values

    * `{:ok, event_map}`: If an event is received within the timeout.
    * `{:error, :timeout}`: If no event is received within the timeout.
  """
  def wait_event(timeout \\ :infinity) do
    receive do
      {:termbox_event, event_map} -> {:ok, event_map}
    after
      timeout -> {:error, :timeout}
    end
  end

  # --- Add get_cell --- #
  @doc """
  Gets the character and attributes of a specific cell from the C helper's buffer.

  Finds the GenServer using the default name `#{@port_handler_key}`.

  Returns `{:ok, %{x: integer, y: integer, char: String.t(), fg: integer, bg: integer}}`
  on success, or `{:error, reason}` on failure.

  Arguments:
    - `x`: The zero-based column index.
    - `y`: The zero-based row index.
  """
  @spec get_cell(integer, integer) :: {:ok, map} | {:error, any()}
  def get_cell(x, y) when is_integer(x) and is_integer(y) do
    # Define the specific call message for CallHandler
    call_msg = {:get_cell, x, y}
    # Use call_genserver helper
    call_genserver(call_msg)
  end
  # --- End get_cell --- #

  @doc """
  Sets the cursor position.

  Finds the GenServer using the default name `#{@port_handler_key}`.

  Arguments:
    - `x`: The zero-based column index (-1 to hide).
    - `y`: The zero-based row index (-1 to hide).
  """
  @spec set_cursor(integer, integer) :: :ok | {:error, any()}
  def set_cursor(x, y) when is_integer(x) and is_integer(y) do
    command_str = ExTermbox.Protocol.format_set_cursor_command(x, y)
    command_key = {:set_cursor, x, y}
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Sets the input mode.

  See `ExTermbox.Const.InputMode` for available modes.

  Arguments:
    - `mode`: An integer representing the input mode.
  """
  @spec set_input_mode(integer) :: :ok | {:error, any()}
  def set_input_mode(mode) when is_integer(mode) do
    command_str = ExTermbox.Protocol.format_set_input_mode_command(mode)
    command_key = {:set_input_mode, mode}
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Sets the output mode.

  See `ExTermbox.Const.OutputMode` for available modes.

  Arguments:
    - `mode`: An integer representing the output mode.
  """
  @spec set_output_mode(integer) :: :ok | {:error, any()}
  def set_output_mode(mode) when is_integer(mode) do
    command_str = ExTermbox.Protocol.format_set_output_mode_command(mode)
    command_key = {:set_output_mode, mode}
    call_genserver({:command, command_key, command_str})
  end

  @doc """
  Sets the default attributes used by `clear/0`.

  See `ExTermbox.Const.Color` and `ExTermbox.Const.Attribute`.

  Arguments:
    - `fg`: The default foreground attribute.
    - `bg`: The default background attribute.
  """
  @spec set_clear_attributes(integer, integer) :: :ok | {:error, any()}
  def set_clear_attributes(fg, bg) when is_integer(fg) and is_integer(bg) do
    command_str = ExTermbox.Protocol.format_set_clear_attributes_command(fg, bg)
    command_key = {:set_clear_attributes, fg, bg}
    call_genserver({:command, command_key, command_str})
  end

  # --- BEGIN ADD DEBUG Event Sender ---
  # @doc ~S"""
  # (For Testing Only) Sends a command to the C process to emit a synthetic event.
  #
  # This bypasses actual terminal interaction and directly triggers the event handling 
  # path for integration testing.
  #
  # The `event_map` should contain keys like `type`, `mod`, `key`, `ch`, `w`, `h`, `x`, `y` 
  # with integer values corresponding to `tb_event` struct fields.
  #
  # **Warning:** This function relies on a debug command in the C helper and should
  # **not** be used in production code.
  # """
  # @spec debug_send_event(map()) :: :ok | {:error, atom() | binary()}
  def debug_send_event(event_map) when is_map(event_map) do
    with type <- Map.get(event_map, :type, 0),
         mod <- Map.get(event_map, :mod, 0),
         key <- Map.get(event_map, :key, 0),
         ch <- Map.get(event_map, :ch, 0),
         w <- Map.get(event_map, :w, 0),
         h <- Map.get(event_map, :h, 0),
         x <- Map.get(event_map, :x, 0),
         y <- Map.get(event_map, :y, 0) do
          
      ExTermbox.PortHandler.debug_send_event(@handler_pid, type, mod, key, ch, w, h, x, y)
    else
      _ -> {:error, :invalid_event_map_for_debug}
    end
  end
  # --- END ADD DEBUG Event Sender ---

  # -- Private Helpers --

  # Helper to make GenServer calls using the local atom name
  # Updated to handle the new {:command, key, string} tuple format
  # And the new PortHandler reply format {:ok, command_key, data} or {:error, command_key, reason}
  defp call_genserver(request_tuple) when is_tuple(request_tuple) do
    call_genserver(request_tuple, @default_timeout)
  end

  defp call_genserver(request_tuple, timeout) when is_tuple(request_tuple) do
    # Use the default atom name
    case GenServer.whereis(@port_handler_key) do
      nil ->
        Logger.error(
          "PortHandler GenServer (#{@port_handler_key}) not running."
        )

        {:error, :not_running}

      pid ->
        # Logger.debug("Found PortHandler PID: #{inspect(pid)}. Sending request: #{inspect(request_tuple)}")
        case GenServer.call(pid, request_tuple, timeout) do
          # PortHandler now replies {:ok, command_key} or {:ok, command_key, data}
          # or {:error, command_key, reason}

          # Simple OK (clear, present, change_cell)
          {:ok, _command_key} ->
            :ok

          # OK with data (width, height)
          {:ok, _command_key, data} ->
            # Attempt to parse integer data, return original string on failure
            case Integer.parse(data) do
              {int_val, ""} ->
                {:ok, int_val}

              _ ->
                Logger.warning(
                  "call_genserver: Expected integer data, got: #{inspect(data)}"
                )

                # Return raw string data if not integer
                {:ok, data}
            end

          # Error from C port, reported via socket
          {:error, _command_key, reason} ->
            {:error, reason}

          # GenServer level errors (:timeout, :busy, :not_initialized, :socket_send_failed etc.)
          {:error, reason} ->
            {:error, reason}

          # Unexpected replies
          other ->
            Logger.error(
              "Received unexpected reply from PortHandler: #{inspect(other)}"
            )

            {:error, {:unexpected_reply, other}}
        end
    end
  end
end
