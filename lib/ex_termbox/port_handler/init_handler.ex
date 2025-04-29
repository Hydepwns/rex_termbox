defmodule ExTermbox.PortHandler.InitHandler do
  require Logger
  alias ExTermbox.Buffer
  alias ExTermbox.ProcessManager

  # Timeout for UDS connection attempt
  @socket_connect_timeout 5000
  # Longer timeout for the multi-stage init process (copied from PortHandler)
  @internal_init_timeout 10_000

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

    case ProcessManager.spawn_port(port_cmd) do
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
      pending_call: {:init, caller_pid}, # Set pending_call to track init process
      buffer: ""
    }

    # Just return OK with the initial state, waiting for port data
    Logger.debug("[InitHandler] Port spawned. Waiting for OK <path> data from port...")
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
  # Removed state argument, only need buffer
  def handle_port_data_init(packet, caller, current_buffer) do
    # Logger.debug("[InitHandler] Received Port Data: #{inspect(packet)}")

    # Use Buffer module to handle potentially fragmented lines
    case Buffer.process(current_buffer, packet) do
      {:lines, lines, remaining_buffer} ->
        # Logger.debug("[InitHandler] Port Buffer processed. Lines: #{inspect(lines)}, Remaining: '#{remaining_buffer}'")

        # Process first line (should be "OK <path>")
        case List.first(lines) do
          nil -> # Should not happen if :lines is returned, but handle defensively
            Logger.warning("[InitHandler] Buffer returned :lines but list was empty.")
            # Keep waiting, update buffer
            {:noreply, %{buffer: remaining_buffer}, @internal_init_timeout}

          first_line ->
            case Protocol.parse_init_response(first_line) do
              {:ok, socket_path_charlist} ->
                # Logger.debug("[InitHandler] Received valid socket path: '#{socket_path_charlist}'")

                # --- Attempt to connect to UDS --- #
                # Logger.debug("[InitHandler] Attempting to connect to UDS: '#{socket_path_charlist}'")

                # Convert path for :gen_tcp / :socket
                # socket_path_binary = List.to_string(socket_path_charlist)
                # Options for UDS connection
                # Active mode set to true to get messages like {:tcp_connected, _}
                opts = [:binary, active: true, packet: :line, reuseaddr: true, local: socket_path_charlist]

                case :gen_tcp.connect(socket_path_charlist, 0, opts) do
                  {:ok, socket_ref} ->
                    # Logger.debug("[InitHandler] :gen_tcp.connect initiated (async). Socket Ref: #{inspect(socket_ref)}")

                    # Transition state: update stage, store socket path, update buffer
                    state_updates = %{
                      init_stage: @init_stage_connecting_socket,
                      socket: socket_path_charlist, # Store the path for now
                      buffer: remaining_buffer # Keep remaining buffer data if any
                      # pending_call remains {:init, caller}
                    }

                    {:noreply, state_updates, @internal_init_timeout}

                  {:error, reason} ->
                    Logger.error(
                      "[InitHandler] Failed to initiate :gen_tcp.connect to '#{socket_path_charlist}': #{inspect(reason)}"
                    )

                    reply_error_and_stop(:socket_connect_failed, reason, caller, socket_path_charlist)
                end
                # --- End Attempt to connect --- #

              {:error, reason} ->
                Logger.error("[InitHandler] Failed to parse init response line: '#{first_line}'. Reason: #{inspect(reason)}")
                reply_error_and_stop(:invalid_init_response, reason, caller, first_line)

            end # case Protocol.parse_init_response
        end # case List.first(lines)

      {:incomplete, new_buffer} ->
        # Logger.debug("[InitHandler] Port Buffer incomplete. New buffer: '#{new_buffer}'")
        # Keep waiting, update buffer
        {:noreply, %{buffer: new_buffer}, @internal_init_timeout}

      other ->
        Logger.error("[InitHandler] Buffer.process returned unexpected: #{inspect(other)}")
        # Treat as error
        reply_error_and_stop(:buffer_error, other, caller, current_buffer)
    end # case Buffer.process
  end

  @doc """
  Handles the successful asynchronous connection of the UDS socket.
  Replies `:ok` to the original `start_link` caller.

  Returns:
  - `{:noreply, state_updates_map, nil}`: Updates state to `:connected`.
  """
  # Removed state argument
  def handle_socket_connect_success(socket_ref, caller) do
    # Logger.debug("[InitHandler] UDS connection successful! Socket: #{inspect(socket_ref)}")

    # Send final success reply to the original caller
    GenServer.reply(caller, {:ok, self()})

    # Update state: mark initialized, store socket ref, clear pending call
    state_updates = %{
      init_stage: @init_stage_connected,
      initialized?: true,
      pending_call: nil, # Init complete
      socket: socket_ref, # Store the active socket reference
      buffer: "" # Clear any remaining port buffer
    }

    # No timeout needed when connected
    {:noreply, state_updates, nil}
  end

  @doc """
  Handles the failure of the asynchronous UDS socket connection attempt.
  Replies `{:error, reason}` to the original `start_link` caller.

  Returns:
  - `{:stop, {:init_failed, reason}, state_updates_map}`: Stops the GenServer.
  """
  # Removed state argument
  def handle_socket_connect_failure(reason, caller, socket_path) do
    Logger.error(
      "[InitHandler] Failed to establish UDS connection to '#{socket_path}'. Reason: #{inspect(reason)}"
    )

    reply_error_and_stop(:socket_connect_failed, reason, caller, socket_path)
  end

  @doc """
  Handles timeouts occurring during the initialization phase.
  Replies `{:error, reason}` to the original `start_link` caller.

  Returns:
  - `{:stop, timeout_reason, state_updates_map}`: Stops the GenServer.
  """
  # Now only takes stage_atom and caller (state passed implicitly via GenServer)
  def handle_init_timeout(type, caller, state) do
    error_reason = 
      case type do
        :port_data -> :timeout_waiting_port_data
        :socket_connect -> :timeout_connecting_socket
        _ -> :unknown_init_timeout
      end
    
    Logger.error("[InitHandler] Initialization timeout occurred: #{error_reason}")

    # Pass state details to the common stop function
    reply_error_and_stop(error_reason, nil, caller, state)
  end

  # --- Private Helpers --- #

  # Helper to parse the "OK <path>" line
  defmodule Protocol do
    require Logger

    # Parses the initial "OK <path>" line from the C port stdout
    def parse_init_response(line) when is_binary(line) do
      trimmed = String.trim(line)
      # Logger.debug("[Protocol] Parsing init response: '#{trimmed}'")

      if String.starts_with?(trimmed, "OK ") do
        path = String.slice(trimmed, 3..-1//-1) |> String.trim()

        if String.length(path) > 0 do
          # Return as charlist for :gen_tcp / :socket
          # Logger.debug("[Protocol] Parsed socket path: '#{path}'")
          {:ok, String.to_charlist(path)}
        else
          Logger.error("[Protocol] Init response 'OK' but path was empty.")
          {:error, :empty_path}
        end
      else
        Logger.error("[Protocol] Unexpected init response format: '#{trimmed}'")
        {:error, :invalid_format}
      end
    end
  end

  defp reply_error_and_stop(reason, caller, state_updates) do
    # Update state: failed, store error, clear pending, clear socket
    state_updates = %{
      init_stage: @init_stage_init_failed,
      last_error: reason,
      pending_call: nil,
      socket: nil
    }

    # Reply error to the original caller
    GenServer.reply(caller, {:error, reason})

    # Return stop tuple
    {:stop, {:init_failed, reason}, state_updates}
  end
end 