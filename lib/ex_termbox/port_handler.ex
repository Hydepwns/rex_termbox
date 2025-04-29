defmodule ExTermbox.PortHandler do
  use GenServer
  require Logger

  # Alias helper modules
  alias ExTermbox.PortHandler.{InitHandler, CallHandler, SocketHandler, TerminationHandler, PortExitHandler}

  # Define module attributes for stages used in guards
  @waiting_port_stage InitHandler.init_stage_waiting_port_data()
  @connecting_socket_stage InitHandler.init_stage_connecting_socket()
  @connected_stage InitHandler.init_stage_connected()

  # Timeout for waiting for command responses from C process
  @timeout 5000 # 5 seconds

  # Updated state: using :port instead of :expty_pid
  @enforce_keys [:owner]
  defstruct owner: nil,
            # Store the Elixir Port reference
            port: nil,
            # Stores socket path (string) during init, then socket reference (port()) after connection
            socket: nil,
            initialized?: false,
            # Initial stage - Call function
            init_stage: InitHandler.init_stage_waiting_port_data(),
            pending_call: nil,
            last_error: nil,
            # Socket buffer for {:tcp, socket, data}
            buffer: ""

  # Client API
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Logger.debug("PortHandler.start_link called with opts: #{inspect(opts)}")
    owner_pid = Keyword.fetch!(opts, :owner)

    if not is_pid(owner_pid) do
      raise ArgumentError, "owner must be a pid"
    end

    name_option = name
    # Call function for timeout
    start_timeout_ms = InitHandler.internal_init_timeout() + 1000

    GenServer.start_link(__MODULE__, opts,
      name: name_option,
      start_timeout: start_timeout_ms
    )
  end

  # Server Callbacks
  @impl true
  def init(opts) when is_list(opts) do
    InitHandler.start_port_and_init(opts)
  end

  # --- handle_call --- #

  # Reject commands if not connected yet
  @impl true
  def handle_call(
        {:command, _command_key, _command_string} = call_msg, # Use underscore for command_key
        _from,
        state = %{init_stage: stage}
      )
      when stage != @connected_stage do # Use module attribute in guard
    CallHandler.handle_call_when_not_connected(call_msg, stage, state)
  end

  # Reject get_cell if not connected yet
  @impl true
  def handle_call(
        {:get_cell, _x, _y} = call_msg,
        _from,
        state = %{init_stage: stage}
      )
      when stage != @connected_stage do
    CallHandler.handle_call_when_not_connected(call_msg, stage, state)
  end

  @impl true
  def handle_call(:trigger_poll_event = call_msg, _from, state = %{init_stage: stage})
      when stage != @connected_stage do # Use module attribute in guard
    CallHandler.handle_call_when_not_connected(call_msg, stage, state)
  end

  # Main handler for sending commands via Socket (when connected)
  @impl true
  def handle_call(
        {:command, command_key, command_string},
        from,
        state = %{socket: socket} # Match only on socket
      )
      when is_port(socket) do
    # Check stage internally (guard using != @connected_stage handles the other case)
    if state.init_stage == @connected_stage do
      # Delegate to CallHandler
      case CallHandler.handle_simple_command(command_key, command_string, from, socket, @timeout) do
        {:noreply, state_updates, timeout} ->
          {:noreply, Map.merge(state, state_updates), timeout}
        {:stop, reason, state_updates} ->
          {:stop, reason, Map.merge(state, state_updates)}
      end
    else
      # This branch should not be reachable due to the guards on the preceding clauses
      Logger.error("Reached unexpected state in handle_call/3 for :command")
      {:reply, {:error, :internal_state_error}, state}
    end
  end

  # Trigger Poll Event (when connected)
  @impl true
  def handle_call(
        :trigger_poll_event,
        _from,
        state = %{socket: socket} # Match only on socket
      )
      when is_port(socket) do
    # Check stage internally (guard using != @connected_stage handles the other case)
    if state.init_stage == @connected_stage do
      # Delegate to CallHandler
      case CallHandler.handle_trigger_poll_event(socket) do
         {:reply, reply, state_updates} ->
           {:reply, reply, Map.merge(state, state_updates)}
         # Should not return noreply or stop for this specific call
         other ->
           Logger.error("CallHandler.handle_trigger_poll_event returned unexpected: #{inspect(other)}")
           {:reply, {:error, :internal_call_handler_error}, state} # Return an error
      end
     else
       # This branch should not be reachable due to the guards on the preceding clauses
       Logger.error("Reached unexpected state in handle_call/3 for :trigger_poll_event")
       {:reply, {:error, :internal_state_error}, state}
     end
  end

  # Handle request to close the port/socket for shutdown
  @impl true
  def handle_call(:request_port_close, from, state) do
     # Delegate to CallHandler - doesn't depend on stage
     case CallHandler.handle_request_port_close(state.socket, state.port) do
        {:reply, reply, state_updates} ->
           # Reply to original caller (`from`) here
           GenServer.reply(from, reply) 
           {:noreply, Map.merge(state, state_updates)} # Change to noreply after replying
        # Should not return noreply or stop
        other ->
          Logger.error("CallHandler.handle_request_port_close returned unexpected: #{inspect(other)}")
         {:reply, {:error, :internal_call_handler_error}, state} # Return an error
     end
  end

  # --- BEGIN ADD GET_CELL handle_call ---
  @impl true
  def handle_call(
        {:get_cell, x, y},
        from,
        state = %{socket: socket}
      )
      when is_port(socket) do
    # Check stage internally
    if state.init_stage == @connected_stage do
      # Delegate to CallHandler.handle_get_cell
      case CallHandler.handle_get_cell(x, y, from, socket, @timeout) do
        {:noreply, state_updates, timeout} ->
          {:noreply, Map.merge(state, state_updates), timeout}
        {:stop, reason, state_updates} ->
          {:stop, reason, Map.merge(state, state_updates)}
      end
    else
      # Should not be reachable due to guard on preceding clause
      Logger.error("Reached unexpected state in handle_call/3 for :get_cell")
      {:reply, {:error, :internal_state_error}, state}
    end
  end
  # --- END ADD GET_CELL handle_call ---

  # --- Handle Info Callbacks ---

  # Dispatcher for handle_info based on init_stage
  @impl true
  def handle_info(msg, state = %{init_stage: stage}) do
    # --- BEGIN DEBUG LOG --- 
    # Logger.debug("PortHandler handle_info RECEIVED: #{inspect(msg)} ---- STATE: #{inspect(state)}")
    # --- END DEBUG LOG --- 

    # Use explicit case based on stage
    case stage do
      stage when stage == @connected_stage ->
        handle_info_connected(msg, state)
      _ -> # Any init stage
        handle_info_init(msg, state)
    end
  end

  # --- Init Phase Handlers (private) --- #

  # Specific init handlers - match on stage inside
  defp handle_info_init(msg, state) do
    case {msg, state.init_stage} do
      # Port Packet (Stage 1: Waiting for Port Data)
      {{port, {:data, packet}}, stage} when stage == @waiting_port_stage ->
         handle_port_data_init_stage(port, packet, state)

      # Socket Connection Success (Stage 2: Connecting Socket)
      {{:tcp_connected, socket}, stage} when stage == @connecting_socket_stage ->
        handle_socket_connect_success_stage(socket, state)

      # Socket Connection Failure (Stage 2: Connecting Socket)
      {{:tcp_error, _socket_ref, reason}, stage} when stage == @connecting_socket_stage ->
         handle_socket_connect_failure_stage(reason, state)

      # Timeout (Stage 1: Waiting for Port Data)
      {:timeout, stage} when stage == @waiting_port_stage ->
        handle_timeout_init_stage(:port_data, state)

      # Timeout (Stage 2: Connecting Socket)
      {:timeout, stage} when stage == @connecting_socket_stage ->
        handle_timeout_init_stage(:socket_connect, state)

      # Port exit during any init phase
      {{port, {:exit_status, status}}, _stage} when state.port == port ->
         handle_port_exit_init_stage(status, state)

      # Catch-all for unexpected messages during init
      {other_msg, other_stage} ->
        Logger.warning(
          "PortHandler (init stage: #{other_stage}) received unexpected message: #{inspect(other_msg)}"
        )
        {:noreply, state}
    end
  end

  # --- Extracted Init Stage Logic (private) --- #

  defp handle_port_data_init_stage(port, packet, state = %{pending_call: {:init, caller}}) do
    # Check port just in case
    if port != state.port do
      Logger.warning("Received data from unexpected port during init: #{inspect(port)}")
      {:noreply, state}
    else
      case InitHandler.handle_port_data_init(packet, caller, state.buffer) do
        {:noreply, state_updates, timeout} ->
          {:noreply, Map.merge(state, state_updates), timeout || :infinity}
        {:stop, reason, state_updates} ->
          {:stop, reason, Map.merge(state, state_updates)}
      end
    end
  end

  defp handle_socket_connect_success_stage(socket, state = %{pending_call: {:init, caller}}) do
    case InitHandler.handle_socket_connect_success(socket, caller) do
      {:noreply, state_updates, timeout} ->
        {:noreply, Map.merge(state, state_updates), timeout || :infinity}
    end
  end

  defp handle_socket_connect_failure_stage(reason, state = %{pending_call: {:init, caller}, socket: socket_path}) do
    case InitHandler.handle_socket_connect_failure(reason, caller, socket_path) do
      {:stop, reason, state_updates} ->
        {:stop, reason, Map.merge(state, state_updates)}
    end
  end

  defp handle_timeout_init_stage(type, state = %{pending_call: {:init, caller}}) do
    case InitHandler.handle_init_timeout(type, caller, state) do
      {:stop, reason, state_updates} ->
        {:stop, reason, Map.merge(state, state_updates)}
    end
  end

  defp handle_port_exit_init_stage(status, state) do
    case PortExitHandler.handle_port_exit(status, state, :init_failed) do
      {:stop, reason, state_updates} ->
        {:stop, reason, Map.merge(state, state_updates)}
      other ->
        Logger.error("PortExitHandler.handle_port_exit returned unexpected: #{inspect(other)}")
        {:stop, {:port_exit_handler_error, other}, Map.merge(state, %{init_stage: InitHandler.init_stage_init_failed(), last_error: :port_exit_handler_error})}
    end
  end

  # --- Connected Phase Handlers (private) --- #

  # Handle incoming data from the UDS socket (when connected)
  defp handle_info_connected({:tcp, socket, data}, state = %{socket: socket}) do
    # Delegate to SocketHandler
    case SocketHandler.handle_socket_data(data, state.buffer, state.pending_call, state.owner) do
      {:noreply, state_updates, timeout} ->
        {:noreply, Map.merge(state, state_updates), timeout || :infinity}
      other -> # e.g. {:incomplete, _} which SocketHandler shouldn't return here
        Logger.error("SocketHandler.handle_socket_data returned unexpected: #{inspect(other)}")
        {:noreply, state} # Keep going, maybe next packet fixes it?
    end
  end

  # Handle socket closed (when connected)
  defp handle_info_connected({:tcp_closed, socket}, state = %{socket: socket}) do
    # Delegate to SocketHandler
    case SocketHandler.handle_socket_closed(state.pending_call, state.owner) do
      {:stop, reason, state_updates} ->
         {:stop, reason, Map.merge(state, state_updates)}
       other ->
         Logger.error("SocketHandler.handle_socket_closed returned unexpected: #{inspect(other)}")
         {:stop, :socket_handler_error, state}
    end
  end

  # Handle socket error (when connected)
  defp handle_info_connected({:tcp_error, socket, reason}, state = %{socket: socket}) do
    # Delegate to SocketHandler
    case SocketHandler.handle_socket_error(reason, state.pending_call, state.owner) do
       {:stop, reason, state_updates} ->
         {:stop, reason, Map.merge(state, state_updates)}
       other ->
         Logger.error("SocketHandler.handle_socket_error returned unexpected: #{inspect(other)}")
         {:stop, :socket_handler_error, state}
    end
  end

  # Handle command timeout (when connected)
  defp handle_info_connected(:timeout, state = %{pending_call: {command_key, from}}) do
     # Delegate to SocketHandler
     case SocketHandler.handle_command_timeout(command_key, from) do
       {:noreply, state_updates, timeout} ->
         {:noreply, Map.merge(state, state_updates), timeout || :infinity}
       # Should not return stop or reply
       other ->
         Logger.error("SocketHandler.handle_command_timeout returned unexpected: #{inspect(other)}")
         {:noreply, state} # Clear pending call manually just in case? No, handle_command_timeout should do it.
     end
  end
  
  # Handle timeout when there's no pending call (ignore)
  defp handle_info_connected(:timeout, state = %{pending_call: nil}) do
     # Logger.debug("Ignoring spurious timeout (no pending call).")
     {:noreply, state}
  end

  # Port exit during connected phase
  defp handle_info_connected({port, {:exit_status, status}}, state = %{port: port}) do
     # Delegate to PortExitHandler, indicating connected context (although it might not use it)
     case PortExitHandler.handle_port_exit(status, state, :connected) do
       {:stop, reason, state_updates} ->
         {:stop, reason, Map.merge(state, state_updates)}
       # PortExitHandler should always return :stop
       other ->
         Logger.error("PortExitHandler.handle_port_exit returned unexpected: #{inspect(other)}")
         {:stop, {:port_exit_handler_error, other}, Map.merge(state, %{init_stage: InitHandler.init_stage_init_failed(), last_error: :port_exit_handler_error})}
     end
  end

  defp handle_info_connected(msg, state) do
    Logger.warning("PortHandler (connected) received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Termination Handling --- #

  @impl true
  def terminate(reason, state) do
    # Delegate to TerminationHandler
    TerminationHandler.terminate(reason, state)
  end

  # --- BEGIN ADD DEBUG Event Sender (PortHandler Client Function) ---
  def debug_send_event(pid, type, mod, key, ch, w, h, x, y) do
    command_str = "DEBUG_SEND_EVENT #{type} #{mod} #{key} #{ch} #{w} #{h} #{x} #{y}"
    # We don't expect a direct reply for this command, 
    # the event message itself is the confirmation. 
    # Using `cast` might be appropriate, but let's use `call` for consistency 
    # and just expect :ok (or timeout/error if C process has issues sending).
    # The C side currently doesn't send an OK for this.
    # Let's just *cast* it and assume it works, the test will assert_receive the event.
    command_key = {:debug_send_event, {type, mod, key, ch, w, h, x, y}}
    GenServer.cast(pid, {:command, command_key, command_str}) 
    :ok # Cast returns immediately
  end
  # --- END ADD DEBUG Event Sender (PortHandler Client Function) ---
end

