defmodule ExTermbox.PortHandler do
  use GenServer
  require Logger

  alias ExTermbox.PortHandler.State # Keep this
  # alias ExTermbox.PortHandler.InitHandler # Remove - Unused
  # alias ExTermbox.PortHandler.CommandHandler # Remove - Calls use full name
  # alias ExTermbox.PortHandler.SocketHandler # Remove - Unused
  alias ExTermbox.ProcessManager # Keep this
  # alias ExTermbox.Buffer # Remove - Unused

  @moduledoc """
  GenServer responsible for managing the Erlang Port connected to the C helper process
  and the Unix Domain Socket (UDS) communication.
  """

  # State: %{
  #   port: port(),
  #   socket: port() | nil, # Connected UDS socket
  #   owner: pid(),
  #   name: atom() | nil,
  #   initialized?: boolean(),
  #   init_stage: :waiting_port_data | :connecting_socket | :connected,
  #   buffer: binary(), # Buffer for socket data
  #   pending_call: {atom(), reference()} | nil,
  #   input_mode: integer() | nil,
  #   output_mode: integer() | nil,
  #   clear_fg: integer() | nil,
  #   clear_bg: integer() | nil
  # }

  # Stage constants - Can be kept or removed if stages are only atoms
  # @waiting_port_stage :waiting_port_data # Use atoms directly
  # @connecting_socket_stage :socket_connecting
  # @connected_stage :init_completed

  # Timeout for port initialization (receiving socket path)
  # @port_init_timeout 5000 # Remove - Currently unused

  # --- Public API ---

  def start_link(opts) do
    name_opt = Keyword.take(opts, [:name])
    Logger.debug("[PortHandler] start_link called with opts: #{inspect(opts)}")
    GenServer.start_link(__MODULE__, opts, name_opt)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(init_args) do
    # Process init_args, e.g., owner PID, config
    owner = Keyword.get(init_args, :owner, self())
    # Get C helper path dynamically using Application.app_dir
    c_helper_path = Application.app_dir(:rrex_termbox, "priv/termbox_port")

    if File.exists?(c_helper_path) do
      # Initial state setup - Use the aliased State
      initial_state = %State{
        owner: owner,
        stage: :port_starting, # Initial stage before triggering port spawn
        stage_state: %{c_helper_path: c_helper_path} # Store path needed for handle_info
        # Other fields default to nil/false/<<>> as per defstruct
      }

      Logger.debug("PortHandler initializing with owner: #{inspect(owner)}, state: #{inspect(initial_state)}")

      # Asynchronously trigger the port process start via handle_info
      send(self(), :start_port_process)

      # Return :ok, state. No timeout here, timeout is handled in handle_info stages.
      {:ok, initial_state}
    else
      Logger.error("Port executable not found at resolved path: #{c_helper_path}")
      # Cannot proceed if the executable isn't found after compile
      {:stop, :port_executable_missing}
    end
  end

  # --- Handle Call --- #

  @impl true
  def handle_call(:request_port_close, _from, state = %{stage: stage}) when stage != :init_completed do
    Logger.warning("Request port close received during init stage: #{stage}. Stopping.")
    {:stop, :shutdown, state}
  end
  def handle_call(:request_port_close, _from, state = %{socket: socket}) do
    Logger.info("[PortHandler] Received :request_port_close. Sending shutdown command via socket.")
    if is_port(socket) do # Check if socket is a valid port/socket reference
      cmd_payload = "shutdown\n"
      case ProcessManager.send_socket(socket, cmd_payload) do
        :ok ->
          Logger.debug("[PortHandler] Sent shutdown command via socket. Stopping GenServer.")
          # We expect the C process to exit, triggering :expty_exit which will clean up.
          # Stop the GenServer now.
          {:stop, :shutdown, state}
        {:error, reason} ->
          Logger.error("[PortHandler] Failed to send shutdown command via socket: #{reason}. Stopping anyway.")
          {:stop, {:shutdown_failed, reason}, state}
      end
    else
      Logger.warning("[PortHandler] Shutdown requested but socket is not active/valid. Stopping directly.")
       {:stop, :shutdown, state}
    end
  end

  @impl true
  def handle_call({:get_cell, _x, _y}, _from, state = %{stage: stage}) when stage != :init_completed do
    Logger.error("Cannot get_cell, not connected. Stage: #{stage}")
    {:reply, {:error, :not_connected}, state}
  end
  def handle_call({:get_cell, x, y}, from, state = %{socket: socket}) when is_port(socket) do
    ExTermbox.PortHandler.CallHandler.handle_get_cell(x, y, from, state)
  end

  @impl true
  def handle_call({:select_input_mode, mode}, _from, state = %{socket: socket}) do
    valid_modes = ExTermbox.Constants.input_modes() |> Map.values()

    if mode in valid_modes do
      cmd_payload = ExTermbox.Protocol.format_set_input_mode_command(mode)
      case ProcessManager.send_socket(socket, cmd_payload) do
         :ok ->
           new_state = Map.merge(state, %{input_mode: mode})
           Logger.debug("[PortHandler] Sent SET_INPUT_MODE command via socket.")
           {:reply, :ok, new_state}
         {:error, reason} ->
           Logger.error("[PortHandler] Failed to send SET_INPUT_MODE command via socket: #{reason}")
           {:reply, {:error, :socket_send_failed}, state}
      end
    else
      Logger.error("Invalid input mode requested: #{inspect(mode)}")
      {:reply, {:error, :invalid_input_mode}, state}
    end
  end

  @impl true
  def handle_call({:command, command_key, _command_string}, _from, state = %{stage: stage}) when stage != :init_completed do
    Logger.error("Cannot process command #{inspect(command_key)}, not connected. Stage: #{stage}")
    {:reply, {:error, :not_connected}, state}
  end
  def handle_call({:command, command_key, command_string}, from, state = %{socket: _socket}) do
    ExTermbox.PortHandler.CallHandler.handle_simple_command(command_key, command_string, from, state)
  end

  @impl true
  def handle_call(:check_init_status, _from, state = %{initialized?: true}) do
    {:reply, :ok, state}
  end
  def handle_call(:check_init_status, _from, state = %{stage: stage}) do
    if stage in [:waiting_pty_data, :socket_connecting] do
      {:reply, {:error, :initializing}, state}
    else
      Logger.debug("check_init_status called in unexpected/failed stage: #{stage}")
      {:reply, {:error, :init_failed}, state}
    end
  end

  # --- Handle Info --- #

  @impl true
  def handle_info(:start_port_process, state = %{stage: :port_starting, stage_state: %{c_helper_path: c_helper_path}}) do
    Logger.debug("[PortHandler] Received :start_port_process. Spawning ExPTY...")

    # Capture owner pid from state for the callbacks
    port_handler_pid = self()

    # Define callbacks
    on_data = fn _expty_pid, _os_pid, data ->
      send(port_handler_pid, {:expty_data, data}) # Send explicitly to PortHandler PID
    end

    on_exit = fn _expty_pid, _os_pid, exit_code, signal_code ->
      send(port_handler_pid, {:expty_exit, {exit_code, signal_code}}) # Send explicitly to PortHandler PID
    end

    # Spawn using ExPTY
    case ExPTY.spawn(c_helper_path, [], on_data: on_data, on_exit: on_exit) do
      {:ok, expty_pid} ->
        Logger.info("[PortHandler] ExPTY process spawned successfully: #{inspect(expty_pid)}. Waiting for socket path via pty.")
        # Update state: store expty_pid, change stage
        new_state = %{state |
          port: nil, # Clear old port field
          expty_pid: expty_pid, # Store the ExPTY pid/reference
          stage: :waiting_pty_data # Use a new stage name
        }
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[PortHandler] Failed to spawn ExPTY process: #{inspect(reason)}")
        {:stop, {:expty_spawn_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:expty_data, packet}, state = %{stage: :waiting_pty_data}) do
    # Use Buffer module to handle potentially fragmented lines
    case ExTermbox.Buffer.process(state.buffer, packet) do
      {:lines, lines, remaining_buffer} ->
        # Find the first line that successfully parses as the socket path
        found_path = Enum.find_value(lines, fn line ->
          case parse_init_response(line) do
            {:ok, socket_path_charlist} ->
              Logger.debug("[PortHandler] Received socket path via ExPTY: #{inspect(socket_path_charlist)}")
              {:ok, socket_path_charlist}
            {:error, :invalid_format} ->
              # Log non-matching lines (e.g., C debug logs)
              Logger.warning("[PortHandler] Received non-init ExPTY data line: #{inspect(line)}")
              nil # Continue searching
            {:error, reason} ->
              # Log actual parsing errors
              Logger.error("[PortHandler] Failed to parse ExPTY init response line '#{line}': #{inspect(reason)}")
              {:error, reason} # Stop searching on error
          end
        end)

        # Process the result of searching lines
        case found_path do
          {:ok, socket_path_charlist} ->
            # Path found, proceed to connect
            new_state = %{state | stage: :socket_connecting, buffer: remaining_buffer}
            {:noreply, new_state, {:continue, {:connect_socket, socket_path_charlist, <<>>}}}
          {:error, reason} ->
            # Parsing error encountered
             {:stop, {:pty_parse_failed, reason}, state}
          nil ->
            # No 'OK <path>' line found yet, keep waiting
            new_state = %{state | buffer: remaining_buffer}
            {:noreply, new_state}
        end

      {:incomplete, new_buffer} ->
        # Keep waiting for a complete line
        new_state = %{state | buffer: new_buffer}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:expty_exit, {exit_code, signal_code}}, state) do
    Logger.error(
      "[PortHandler] ExPTY process exited. Stage: #{state.stage}, Exit Code: #{exit_code}, Signal: #{signal_code}"
    )
    # Use the existing PortExitHandler logic, adapting as needed
    status = {exit_code, signal_code}
    ExTermbox.PortHandler.PortExitHandler.handle_port_exit(status, state)
  end

  @impl true
  def handle_info(msg, state = %{stage: :socket_connecting}) do
    # Handle other messages during socket connecting (e.g., timeout, maybe more pty data?)
    case msg do
      {:timeout, :socket_connecting} -> # Assuming timeout is set in handle_continue
        Logger.error("[PortHandler] Timeout during socket connection stage.")
        {:stop, :socket_connect_timeout, state}

      {:expty_data, packet} ->
        # Ignore extra pty data while connecting socket?
        Logger.warning("[PortHandler] Received unexpected ExPTY data during socket connect: #{inspect(packet)}")
        {:noreply, state}

      other_msg ->
        Logger.warning(
          "PortHandler (socket connecting) received unexpected message: #{inspect(other_msg)}"
        )
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state = %{stage: :init_completed}) do
    case msg do
      # Handle PTY data (e.g., debug output from C?) when connected?
      {:expty_data, data} ->
         Logger.debug("[PortHandler] Received PTY data while connected: #{inspect(data)}")
         # We don't expect critical data here now, mostly socket comms
         {:noreply, state}

      # Handle socket data (existing logic)
      {:tcp, socket, data} when socket == state.socket ->
        {:noreply, state_updates, timeout} = ExTermbox.PortHandler.SocketHandler.handle_socket_data(data, state.buffer, state.pending_call, state.owner)
        new_state = Map.merge(state, state_updates)
        {:noreply, new_state, timeout}

      # Handle socket close (existing logic)
      {:tcp_closed, socket} when socket == state.socket ->
        {:stop, reason, state_updates} = ExTermbox.PortHandler.SocketHandler.handle_socket_closed(state.pending_call, state.owner)
        new_state = Map.merge(state, state_updates)
        {:stop, reason, new_state}

      # Handle socket error (existing logic)
      {:tcp_error, socket, reason} when socket == state.socket ->
        {:stop, stop_reason, state_updates} = ExTermbox.PortHandler.SocketHandler.handle_socket_error(reason, state.pending_call, state.owner)
        new_state = Map.merge(state, state_updates)
        {:stop, stop_reason, new_state}

      # ExPTY exit is handled by the general :expty_exit clause

      other_msg ->
        Logger.warning(
          "PortHandler (connected) received unexpected message: #{inspect(other_msg)}"
        )
        {:noreply, state}
    end
  end

  # --- Handle Continue --- #

  @impl true
  def handle_continue({:connect_socket, socket_path_charlist, remaining_buffer}, state) do
    socket_path_string = to_string(socket_path_charlist)
    Logger.debug(
      "[PortHandler] handle_continue connecting to socket '#{socket_path_string}'..."
    )

    if File.exists?(socket_path_string) do
      case ProcessManager.connect_socket(socket_path_charlist) do
        {:ok, socket_ref} ->
          Logger.info("[PortHandler] Socket connected successfully. Ref: #{inspect(socket_ref)}")
          new_state = %{
            state
            | socket: socket_ref,
              initialized?: true,
              stage: :init_completed,
              buffer: remaining_buffer
          }
          {:noreply, new_state, :hibernate}

        {:error, reason} ->
          Logger.error("[PortHandler] Socket connection failed: #{inspect(reason)}")
          {:stop, {:socket_connect_failed, reason}, state}
      end
    else
      Logger.error("[PortHandler] Socket file does not exist at path: #{socket_path_string}")
      {:stop, {:socket_connect_failed, :enoent}, state}
    end
  end

  # --- Terminate --- #
  @impl true
  def terminate(reason, state) do
     ExTermbox.PortHandler.TerminationHandler.terminate(reason, state)
     :ok
  end

  defp parse_init_response(line) when is_binary(line) do
    cleaned_line = line |> :binary.replace("\r\n", "\n") |> String.trim()
    parts = String.split(cleaned_line, " ", parts: 2)

    case parts do
      ["OK", path] ->
        {:ok, String.to_charlist(path)}
      ["ERROR", reason] ->
        {:error, {:port_error, reason}}
      _ ->
        {:error, :invalid_format}
    end
  end
end 