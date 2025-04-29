# Define the registry module first
# defmodule ExTermbox.Registry do
#   use Elixir.Registry, keys: :unique, name: ExTermbox.Registry.Supervisor
# end

defmodule ExTermbox do
  require Logger
  # require ExTermbox.Constants # Alias is enough
  alias ExTermbox.Constants
  alias ExTermbox.Protocol # Add alias here

  # Define the registry
  # defmodule Registry, do: use(Elixir.Registry, keys: :unique, name: __MODULE__.Registry)

  # Define common type for pid() or registered name atom()
  @type pid_or_name :: pid() | atom()

  # Default atom name for local registration
  # Make it slightly more specific
  # @port_handler_key :ex_termbox_port_handler

  @moduledoc """
  Elixir bindings for the termbox library, providing a way to control the
  terminal and draw simple UIs.

  This module provides the main user-facing API. It interacts with a C process
  via an Elixir Port managed by the `ExTermbox.PortHandler` GenServer.

  ## Usage

  1.  **Initialization:** Call `ExTermbox.init/1` to start the necessary processes.
      This returns `{:ok, pid}` where `pid` is the handler process.
      This must be called before any other functions.
  2.  **API Calls:** Use functions like `change_cell/6`, `clear/1`, etc., passing
      the `pid` obtained from `init/1` as the first argument.
  3.  **Display:** Call `ExTermbox.present/1` (passing the `pid`) to flush the
      back buffer to the terminal screen.
  4.  **Events:** Call `ExTermbox.poll_event/1` (passing the `pid`) to wait for
      user input or resize events. These will be sent as messages to the process
      that called `init/1` (the owner).
  5.  **Shutdown:** Call `ExTermbox.shutdown/1` (passing the `pid`) when finished
      to clean up.

  ## Event Handling

  Events are delivered as messages in the format `{:termbox_event, event_map}`
  to the process that called `init/1`. See `ExTermbox.PortHandler` for details
  on the event map structure. You typically need to call `poll_event/1` again
  after receiving an event to wait for the next one.

  Example (`handle_info` in the process that called `init/1`):

  ```elixir
  def handle_info({:termbox_event, event}, state) do
    # Assuming handler_pid is stored in state
    handler_pid = state.handler_pid
    IO.inspect(event, label: "Received Termbox Event")
    # Request next event, passing the pid
    ExTermbox.poll_event(handler_pid)
    {:noreply, state}
  end
  ```
  """

  @doc """
  Initializes the termbox library.

  Starts the PortHandler GenServer.
  Returns `{:ok, pid}` on success, where `pid` is the PortHandler process ID,
  or `{:error, reason}` on failure.

  Options:
    - `name`: Registers the GenServer under a specific name.
    - `owner`: Specifies the owner process (defaults to `self()`).
  """
  @spec init(keyword) :: {:ok, pid} | {:error, any}
  def init(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())
    handler_opts = opts

    Logger.debug(
      "ExTermbox.init starting PortHandler with opts: #{inspect(handler_opts)}"
    )

    case ExTermbox.PortHandler.start_link(handler_opts) do
      {:ok, pid} ->
        name_used = Keyword.get(handler_opts, :name)
        Logger.debug(
          "PortHandler started. PID: #{inspect(pid)}, Name: #{inspect(name_used)}. Waiting for initialization..."
        )

        # Wait for the handler to be fully initialized using recursive check
        wait_for_init(pid, 100) # Retry 100 times (e.g., 100 * 50ms = 5s)

      {:error, reason} = error_reply ->
        Logger.error("PortHandler start_link failed directly: #{inspect(reason)}")
        error_reply
    end
  end

  # Recursive helper to wait for :check_init_status to return :ok
  defp wait_for_init(pid, retries_left) when retries_left > 0 do
    # Wrap GenServer.call in try/catch
    try do
      case GenServer.call(pid, :check_init_status, 500) do # Short timeout for each check
        :ok ->
          Logger.debug("PortHandler reported initialized. ExTermbox.init returning {:ok, pid}.")
          {:ok, pid}

        {:error, :initializing} ->
          Process.sleep(50) # Wait briefly before retrying
          wait_for_init(pid, retries_left - 1)

        {:error, reason} -> # Init failed in PortHandler
          Logger.error(
            "PortHandler initialization check failed: #{inspect(reason)}. Stopping handler."
          )
          GenServer.stop(pid, :shutdown)
          {:error, {:init_failed, reason}}

        other -> # Unexpected reply
          Logger.error(
            "PortHandler initialization check returned unexpected: #{inspect(other)}. Stopping handler."
          )
          GenServer.stop(pid, :shutdown)
          {:error, {:init_failed, {:unexpected_status, other}}}
      end
    catch
      # Catch GenServer.call timeout or exit exceptions
      type, reason ->
        Logger.error(
          "Error calling :check_init_status (Type: #{type}): #{inspect(reason)}. Stopping handler."
        )
        # Ensure handler is stopped if call fails
        _ = GenServer.stop(pid, :shutdown)
        {:error, {:init_failed, {type, reason}}}
    end
  end

  # Base case: Ran out of retries
  defp wait_for_init(pid, 0) do
    Logger.error("Timeout waiting for PortHandler initialization after multiple retries.")
    _ = GenServer.stop(pid, :shutdown)
    {:error, :init_timeout}
  end

  @doc """
  Shuts down the termbox library and stops the PortHandler GenServer.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec shutdown(pid | atom) :: :ok | {:error, any}
  def shutdown(pid_or_name), do: call_genserver(pid_or_name, :request_port_close)

  @doc """
  Returns the width of the terminal.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec width(pid | atom) :: {:ok, non_neg_integer} | {:error, any}
  def width(pid_or_name) do
    command_key = :width
    command_string = ExTermbox.Protocol.format_width_command()
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  @doc """
  Returns the height of the terminal.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec height(pid | atom) :: {:ok, non_neg_integer} | {:error, any}
  def height(pid_or_name) do
    command_key = :height
    command_string = ExTermbox.Protocol.format_height_command()
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  # --- BEGIN ADD select_input_mode ---
  @doc """
  Selects the input mode.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `mode`: An atom representing the input mode (e.g., `ExTermbox.Const.Input.ESC`).
  """
  @spec select_input_mode(pid_or_name, atom) :: :ok | {:error, any()}
  def select_input_mode(pid_or_name, mode) when is_atom(mode) do
    try do
      mode_int = Constants.input_mode(mode)
      cmd_payload = Protocol.format_set_input_mode_command(mode_int)
      call_genserver(pid_or_name, {:command, :set_input_mode, cmd_payload})
    catch
      :error, {:key_not_found, _, _} -> {:error, :invalid_input_mode}
      e -> {:error, {:internal_error, e}}
    end
  end

  # --- END ADD select_input_mode ---

  # --- Add other functions like clear, present, change_cell, poll_event here ---

  @doc """
  Clears the terminal buffer using the default colors.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec clear(pid | atom) :: :ok | {:error, any}
  def clear(pid_or_name) do
    command_key = :clear
    command_string = ExTermbox.Protocol.format_clear_command()
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  @doc """
  Synchronizes the back buffer with the terminal screen.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec present(pid | atom) :: :ok | {:error, any}
  def present(pid_or_name) do
    command_key = :present
    command_string = ExTermbox.Protocol.format_present_command()
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  @doc """
  Changes the character, foreground, and background attributes of a specific cell.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `x`: The zero-based column index.
    - `y`: The zero-based row index.
    - `char`: The character (as a single-char string or integer codepoint).
    - `fg`: The foreground attribute (e.g., `ExTermbox.Const.Color.RED`).
    - `bg`: The background attribute (e.g., `ExTermbox.Const.Attribute.BOLD`).
  """
  def change_cell(pid_or_name, x, y, char, fg, bg)
      when is_integer(x) and is_integer(y) and is_integer(fg) and is_integer(bg) do
    codepoint =
      if is_integer(char),
        do: char,
        else: char |> String.to_charlist() |> List.first()

    # Format using Protocol module
    command_str =
      ExTermbox.Protocol.format_change_cell_command(x, y, codepoint, fg, bg)

    # Identify the command by atom/tuple for pending_call matching
    command_key = :change_cell

    call_genserver(pid_or_name, {:command, command_key, command_str})
  end

  @doc """
  Prints a string at the specified position with given attributes.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `x`: The zero-based column index for the start of the string.
    - `y`: The zero-based row index for the start of the string.
    - `fg`: The foreground attribute (e.g., `ExTermbox.Const.Color.RED`).
    - `bg`: The background attribute (e.g., `ExTermbox.Const.Attribute.BOLD`).
    - `string`: The string to print.
  """
  @spec print(pid_or_name, integer, integer, atom, atom, String.t()) :: :ok | {:error, any()}
  def print(pid_or_name, x, y, fg, bg, string) when is_integer(x) and is_integer(y) and is_atom(fg) and is_atom(bg) and is_binary(string) do
    try do
      fg_int = Constants.color(fg)
      bg_int = Constants.color(bg)
      cmd_payload = Protocol.format_print_command(x, y, fg_int, bg_int, string)
      call_genserver(pid_or_name, {:command, :print, cmd_payload})
    catch
      :error, {:key_not_found, key, _} -> {:error, {:invalid_color, key}}
      e -> {:error, {:internal_error, e}}
    end
  end

  @doc """
  Retrieves the content of a specific cell from the back buffer.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `x`: The zero-based column index.
    - `y`: The zero-based row index.

  Returns `{:ok, cell_map}` or `{:error, reason}`.
  The `cell_map` has keys `:x, :y, :char, :fg, :bg`.
  """
  @spec get_cell(pid | atom, integer, integer) ::
          {:ok, map} | {:error, any}
  def get_cell(pid_or_name, x, y) when is_integer(x) and is_integer(y) do
    command_key = {:get_cell, x, y}
    command_string = ExTermbox.Protocol.format_get_cell_command(x, y)
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  @doc """
  Sets the cursor position. Use `(-1, -1)` to hide the cursor.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `x`: The zero-based column index, or -1 to hide.
    - `y`: The zero-based row index, or -1 to hide.
  """
  @spec set_cursor(pid | atom, integer, integer) :: :ok | {:error, any}
  def set_cursor(pid_or_name, x, y) when is_integer(x) and is_integer(y) do
    command_key = :set_cursor
    command_string = ExTermbox.Protocol.format_set_cursor_command(x, y)
    call_genserver(pid_or_name, {:command, command_key, command_string})
  end

  @doc """
  Selects the output mode.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `mode`: An atom representing the output mode (e.g., `ExTermbox.Const.OutputMode.C256`).
  """
  @spec set_output_mode(pid_or_name, atom) :: :ok | {:error, any()}
  def set_output_mode(pid_or_name, mode) when is_atom(mode) do
    try do
      mode_int = Constants.output_mode(mode)
      cmd_payload = Protocol.format_set_output_mode_command(mode_int)
      call_genserver(pid_or_name, {:command, :set_output_mode, cmd_payload})
    catch
      :error, {:key_not_found, _, _} -> {:error, :invalid_output_mode}
      e -> {:error, {:internal_error, e}}
    end
  end

  @doc """
  Sets the default foreground and background attributes used by `clear/1`.

  Requires the PID or registered name of the PortHandler process.

  Arguments:
    - `pid_or_name`: The PID or registered name of the PortHandler.
    - `fg`: The foreground attribute.
    - `bg`: The background attribute.
  """
  @spec set_clear_attributes(pid_or_name, atom, atom) :: :ok | {:error, any()}
  def set_clear_attributes(pid_or_name, fg, bg) when is_atom(fg) and is_atom(bg) do
    try do
      fg_int = Constants.color(fg)
      bg_int = Constants.color(bg)
      cmd_payload = Protocol.format_set_clear_attributes_command(fg_int, bg_int)
      call_genserver(pid_or_name, {:command, :set_clear_attributes, cmd_payload})
    catch
      :error, {:key_not_found, key, _} -> {:error, {:invalid_color, key}}
      e -> {:error, {:internal_error, e}}
    end
  end

  @doc """
  Requests the PortHandler to poll for the next event.
  This is typically called after handling a previous event.
  The event will be delivered asynchronously to the owning process.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec poll_event(pid | atom) :: :ok | {:error, any}
  def poll_event(pid_or_name) do
    # This might be better as a cast if no reply is needed?
    # But a call confirms the command was sent okay.
    call_genserver(pid_or_name, :trigger_poll_event)
  end

  @doc """
  [Debug] Sends a synthetic event for testing purposes.

  Requires the PID or registered name of the PortHandler process.
  """
  @spec debug_send_event(pid | atom, map) :: :ok | {:error, any}
  def debug_send_event(pid_or_name, event_map) when is_map(event_map) do
    command_key = :debug_send_event
    # Extract fields and call the correct format function
    command_string = ExTermbox.Protocol.format_debug_send_event_command(
      Map.get(event_map, :type, 0),
      Map.get(event_map, :mod, 0),
      Map.get(event_map, :key, 0),
      Map.get(event_map, :ch, 0),
      Map.get(event_map, :w, 0),
      Map.get(event_map, :h, 0),
      Map.get(event_map, :x, 0),
      Map.get(event_map, :y, 0)
    )
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
