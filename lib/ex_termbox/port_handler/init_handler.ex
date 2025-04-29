defmodule ExTermbox.PortHandler.InitHandler do
  @moduledoc """
  Handles the initialization logic (`init/1` callback and related messages) for `ExTermbox.PortHandler`.
  """
  require Logger
  alias ExTermbox.Buffer

  # Timeout for UDS connection attempt - REMOVED as unused
  # @socket_connect_timeout 5000
  # Timeout for the entire internal init process (waiting for port data + UDS connect)
  @internal_init_timeout :timer.seconds(10)
  # Timeout specifically for the :gen_unix.connect call
  # @connect_timeout_ms 5000 # 5 seconds

  # Stages for initialization using Ports & Sockets
  # Waiting for OK <socket_path> from C port stdout
  @init_stage_waiting_port_data :waiting_port_data
  # Trying to connect to the received socket path
  @init_stage_connecting_socket :connecting_socket
  # Final success state (Port open, Socket connected)
  @init_stage_connected :connected
  # Final failure state during initialization
  @init_stage_init_failed :init_failed

  # Public functions to access stage values
  def init_stage_waiting_port_data, do: @init_stage_waiting_port_data
  def init_stage_connecting_socket, do: @init_stage_connecting_socket
  def init_stage_connected, do: @init_stage_connected
  def init_stage_init_failed, do: @init_stage_init_failed

  # Public function to access timeout value
  def internal_init_timeout, do: @internal_init_timeout

  # --- Public Functions (called by PortHandler) ---

  @doc """
  The main entry point for PortHandler initialization.
  Finds the C helper, spawns the Port, sends the initial trigger,
  and returns the initial state or stop reason.
  """
  def start_port_and_init(opts) when is_list(opts) do
    owner_pid = Keyword.fetch!(opts, :owner)
    # Link to owner process (done here as it's part of init setup)
    Process.link(owner_pid)

    Logger.info(
      "--- PortHandler init/1 started (Using Ports) --- (Owner: #{inspect(owner_pid)}) "
    )

    priv_dir = Application.app_dir(:rrex_termbox, "priv")
    port_cmd = Path.join(priv_dir, "termbox_port")

    if !File.exists?(port_cmd) do
      Logger.error("Port executable not found at #{port_cmd}")
      Logger.error("Ensure you have compiled the C code (mix compile).")

      # Use exit here as it's a fatal setup error before the GenServer process loop starts
      exit({:shutdown, :port_executable_not_found})
    end

    Logger.info("Executable exists.")
    Logger.info("Attempting Port spawn via ProcessManager...")

    case ExTermbox.ProcessManager.spawn_port(port_cmd) do
      # Case 1: ProcessManager wrapped success (less likely based on current PM code)
      {:ok, port} when is_port(port) ->
        Logger.info(
          "Port started successfully (received {:ok, port}). Port ID: #{inspect(port)}"
        )

        post_port_spawn_setup(port, owner_pid, self())

      # Case 2: Direct port return (most likely scenario based on Port.open behaviour)
      port when is_port(port) ->
        Logger.info(
          "Port started successfully (received port directly). Port ID: #{inspect(port)}"
        )

        post_port_spawn_setup(port, owner_pid, self())

      # Case 3: ProcessManager returned an error tuple
      {:error, reason} ->
        Logger.error(
          "Failed to start Port via ProcessManager: #{inspect(reason)}"
        )

        {:stop, {:port_spawn_failed, reason}}

      # Catch-all for unexpected returns
      unexpected ->
        Logger.error(
          "Unexpected return value from ProcessManager.spawn_port: #{inspect(unexpected)}"
        )

        {:stop, {:port_spawn_failed, {:unexpected_return, unexpected}}}
    end
  end

  # Helper for successful init after port is opened
  # Takes the port, owner_pid, and the caller_pid (which is the PortHandler GenServer itself)
  # Returns the standard GenServer init tuple: {:ok, state, timeout} or {:stop, reason}
  defp post_port_spawn_setup(port, owner_pid, caller_pid) do
    # Note: state struct is defined in PortHandler, we create a map representation here
    # for the initial state. The GenServer behavior merges this into the actual state struct.
    initial_state_map = %{
      owner: owner_pid,
      port: port,
      socket: nil,
      initialized?: false,
      init_stage: @init_stage_waiting_port_data,
      # Set pending_call to track init process
      pending_call: {:init, caller_pid},
      buffer: ""
    }

    # Just return OK with the initial state, waiting for port data
    Logger.debug(
      "[InitHandler] Port spawned. Waiting for OK <path> data from port..."
    )

    {:ok, initial_state_map, @internal_init_timeout}
  end

  @doc """
  Handles incoming data packets received via the Port during the initial phase.
  It buffers data and attempts to parse the 'OK <socket_path>' line.
  Once the path is found, it initiates the UDS connection attempt.

  Returns:
  - `{:noreply, state_updates_map, timeout | nil}`: If more data is needed or connection started.
  - `{:stop, reason, state_updates_map}`: If parsing fails or connection initiation fails.
  """
  # Accept the full state map
  def handle_port_data_init(packet, state) do
    # Use Buffer module to handle potentially fragmented lines
    case Buffer.process(state.buffer, packet) do
      {:lines, lines, remaining_buffer} ->
        # Pass state down
        _handle_parsed_lines(lines, remaining_buffer, state)

      {:incomplete, new_buffer} ->
        # Logger.debug("[InitHandler] Port Buffer incomplete. New buffer: '#{new_buffer}'")
        # Keep waiting, update buffer
        {:noreply, %{buffer: new_buffer}, @internal_init_timeout}

      other ->
        Logger.error(
          "[InitHandler] Buffer.process returned unexpected: #{inspect(other)}"
        )

        # Pass state.pending_call to reply helper
        reply_error_and_stop(:buffer_error, other, state.pending_call)
    end
  end

  # --- BEGIN Extracted Helper for handle_port_data_init ---
  # Accept state map
  defp _handle_parsed_lines(lines, remaining_buffer, state) do
    # Process first line (should be "OK <path>")
    case List.first(lines) do
      nil ->
        Logger.warning(
          "[InitHandler] Buffer returned :lines but list was empty."
        )

        # Keep waiting, update buffer
        {:noreply, %{buffer: remaining_buffer}, @internal_init_timeout}

      first_line ->
        case parse_init_response(first_line) do
          {:ok, socket_path_charlist} ->
            # Pass state down
            handle_socket_connection_stage(
              socket_path_charlist,
              remaining_buffer,
              Map.merge(state, %{pending_call: state.pending_call})
            )

          {:error, reason} ->
            Logger.error(
              "[InitHandler] Failed to parse socket path from port data: #{inspect(reason)}"
            )
            reply_error_and_stop(:parse_socket_path_failed, reason, state.pending_call)
        end
    end
  end

  # --- Extracted Helper for handle_port_data_init ---
  # Handles the stage where we have received the socket path from the port process.
  # Attempts to connect to the socket and transitions state based on outcome.
  defp handle_socket_connection_stage(
         socket_path_charlist, # Socket path (charlist) received from port
         remaining_buffer, # Any remaining data in buffer after parsing path
         state # Current PortHandler state
       ) do
    # Convert path for logging/checking
    socket_path_string = to_string(socket_path_charlist)

    Logger.debug(
      "[InitHandler] Received socket path from port process: \'#{socket_path_string}\'"
    )
    Logger.info(
      "[InitHandler] Scheduling connection attempt to \'#{socket_path_string}\' via handle_continue (removed File.exists? check)..."
    )
    # Directly schedule the connection attempt in handle_continue
    {:noreply, Map.put(state, :init_stage, @init_stage_connecting_socket),
     {:continue, {:connect_socket, socket_path_charlist, remaining_buffer}}}
  end
  # --- END Extracted Helper ---

  # --- handle_continue for socket connection ---
  # Performs the actual socket connection attempt using ProcessManager.
  # This function is called by PortHandler's handle_continue when the
  # {:continue, {:connect_socket, path, buffer}} tuple is received.
  def do_connect_socket(socket_path_charlist, remaining_buffer, state) do
    # Delay before connect (temporary workaround - consider removing)
    # Process.sleep(100)

    socket_path_string = to_string(socket_path_charlist)
    Logger.debug(
      "[InitHandler] Connecting to socket '#{socket_path_string}' via ProcessManager.connect_socket..."
    )

    case ExTermbox.ProcessManager.connect_socket(socket_path_charlist) do
      {:ok, socket_ref} ->
        Logger.info(
          "[InitHandler] Socket connected successfully via ProcessManager. Socket Ref: #{inspect(socket_ref)}"
        )
        # Successful connection, reply to caller
        {:ok, caller} = state.pending_call
        GenServer.reply(caller, :ok)

        state_updates = %{
          init_stage: @init_stage_connected,
          initialized?: true,
          socket: socket_ref,
          pending_call: nil,
          buffer: remaining_buffer # Use remaining buffer from port data
        }
        # Transition complete, clear internal timeout
        {:noreply, state_updates, nil} # Use nil timeout as connect is sync

      {:error, reason} ->
        Logger.error(
          "[InitHandler] Failed ProcessManager.connect_socket to '#{socket_path_string}': #{inspect(reason)}"
        )
        reply_error_and_stop(:socket_connect_failed, reason, state.pending_call)
    end
  end
  # --- END handle_continue ---

  @doc """
  Handles a timeout during the initialization phase.
  Replies error to the original `start_link` caller and prepares state for stop.
  """
  def handle_init_timeout(type, _pending_call = {:init, caller}, state) do
    timeout_reason =
      case type do
        :port_data -> :timeout_waiting_port_data
        :socket_connect -> :timeout_connecting_socket
        _ -> :unknown_init_timeout
      end

    Logger.error("[InitHandler] Initialization timed out: #{timeout_reason}")

    # Reply error to the original caller
    final_reason = {:init_failed, timeout_reason}
    GenServer.reply(caller, {:error, final_reason})

    # Update state for stopping
    state_updates = %{
      init_stage: @init_stage_init_failed,
      initialized?: false,
      pending_call: nil,
      last_error: timeout_reason
    }

    {:stop, final_reason, Map.merge(state, state_updates)}
  end

  # --- Private Helper Functions ---

  # Parses "OK <path>" or "ERROR <reason>"
  defp parse_init_response(line) do
    # Use String.split and handle potential missing space
    parts = String.split(line, " ", parts: 2)

    case parts do
      ["OK", path] ->
        # Trim whitespace (like trailing newlines) before converting
        cleaned_path = String.trim(path)
        # Return path as charlist for :gen_unix
        {:ok, String.to_charlist(cleaned_path)}

      # Handle ERROR case if C port sends it this way
      ["ERROR", reason] ->
        {:error, {:port_error, reason}}

      # Handle edge cases: empty line, only "OK", etc.
      _ ->
        {:error, :invalid_format}
    end
  end

  # Reply error and stop (helper)
  defp reply_error_and_stop(type, reason, _pending_call) do
    response = {:error, {:init_failed, {type, reason}}}

    Logger.error(
      "[InitHandler] Returning stop tuple due to error: #{inspect(response)}"
    )

    # REMOVED: GenServer.reply(caller, response)
    {:stop, {:shutdown, {type, reason}}, %{}}
  end

  # --- Internal Helper Functions ---

  # Removed - Logic handled in PortHandler.handle_continue({:connect_socket, ...})
  # defp handle_socket_connection_stage(%State{socket: nil, stage_state: %{socket_path: path}} = state) do
  #   if File.exists?(path) do
  #     Logger.debug("[InitHandler] Socket file exists at: #{path}. Scheduling connection attempt.")
  #     schedule_connect_socket(state, path)
  #   else
  #     Logger.error("[InitHandler] Socket file does not exist at path: #{path}")
  #     reply_error_and_stop(state, {:socket_connect_failed, :enoent})
  #   end
  # end

  # Removed - Unused after refactoring
  # defp schedule_connect_socket(state, path_charlist) do
  #   Logger.info("[InitHandler] Initiating socket connection via handle_continue.")
  #   # The actual connection is triggered in handle_continue
  #   {:noreply, Map.put(state, :stage, :socket_connecting), {:continue, {:connect_socket, path_charlist, <<>>}}}
  # end

  # Removed - Unused
  # defp reply_error_and_stop(state, reason) do
  #   # In async init, we can't easily reply. Stop the GenServer.
  #   # The owner process should monitor this process.
  #   {:stop, reason, state}
  # end

end # End of module
