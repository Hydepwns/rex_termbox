defmodule ExTermbox.InitHandler do
  @moduledoc """
  Handles the initialization sequence within the PortHandler GenServer.
  This module encapsulates the logic for parsing port output, managing
  timeouts, and establishing the UDS connection.
  """
  # No need for 'use GenServer' here as this module only provides helper functions
  # called by PortHandler, it's not a GenServer itself.
  require Logger

  @socket_connect_timeout 5000 # Timeout for socket connect
  @uds_connect_delay 100 # Re-add a smaller delay (100ms)

  # --- Public API (Called by PortHandler) ---

  @doc """
  Called by PortHandler when it receives data from the port during initialization.
  Parses the data to find the socket path.
  Transitions PortHandler state to :connecting_socket or stops on error.
  """
  def handle_port_data_init(packet, state = %{pending_call: {:init, caller}}) do
    case parse_port_output(packet) do
      {:ok, socket_path} ->
        Logger.debug("[InitHandler] Received socket path: \"#{socket_path}\"")

        # Schedule the connection attempt after a delay
        Process.send_after(self(), {:continue, :attempt_socket_connect, socket_path}, @uds_connect_delay)

        new_state = Map.merge(state, %{
          init_stage: :connecting_socket,
          socket: socket_path # Store the path we intend to connect to
        })

        {:noreply, new_state, @socket_connect_timeout}

      {:error, :invalid_format} ->
        Logger.error("[InitHandler] Port output format invalid: #{inspect(packet)}")
        GenServer.reply(caller, {:error, {:init_failed, :invalid_port_output}})
        {:stop, {:shutdown, :invalid_port_output}, state}

      {:error, reason} ->
        Logger.error("[InitHandler] Error parsing port output: #{inspect(reason)}")
        GenServer.reply(caller, {:error, {:init_failed, reason}})
        {:stop, {:shutdown, reason}, state}
    end
  end

  @doc """
  Called by PortHandler via :continue after the UDS connect delay.
  Checks socket existence and attempts connection.
  """
  def handle_continue_attempt_connect(socket_path, state = %{pending_call: {:init, caller}}) do
    if File.exists?(socket_path) do
      Logger.debug("[InitHandler] Socket file exists at path: #{socket_path}")
      # --- BEGIN ADDED DEBUG --- #
      try do
        file_stat = File.stat!(socket_path)
        Logger.debug("[InitHandler] Socket file stat: #{inspect(file_stat)}")
      rescue e ->
        Logger.error("[InitHandler] Failed to stat socket file #{socket_path}: #{inspect(e)}")
      end
      # --- END ADDED DEBUG --- #
      # Ensure correct log message is present
      Logger.debug("[InitHandler] Calling ExTermbox.ProcessManager.connect_socket via handle_continue...")

      # Corrected: Use full alias
      # Corrected: Remove unused timeout option
      case ExTermbox.ProcessManager.connect_socket(socket_path) do
        {:ok, socket} ->
          # Connection successful immediately
          # Call the success handler directly instead of waiting for a message
          handle_socket_connect_success(socket, caller)

        {:error, reason} ->
          # Connection failed immediately
          # Call the failure handler directly, passing the current state
          handle_socket_connect_failure(reason, socket_path, caller, state)
      end
    else
      Logger.error("[InitHandler] Socket file does not exist after delay: #{socket_path}")
      reason = :socket_file_missing
      GenServer.reply(caller, {:error, {:init_failed, reason}})
      {:stop, {:shutdown, reason}, state}
    end
  end


  @doc """
  Called by PortHandler when the :gen_tcp socket connection succeeds.
  Replies :ok to the original caller and transitions PortHandler state.
  """
  def handle_socket_connect_success(socket, caller) do
    Logger.info("[InitHandler] Socket connection established successfully.")
    # Reply success to the original caller of ExTermbox.init/1
    GenServer.reply(caller, :ok)

    # Return state updates for PortHandler
    state_updates = %{
      socket: socket,
      init_stage: :connected # Final init stage
    }
    # {:noreply, state_updates, timeout}
    # Using :infinity timeout as init is complete
    {:noreply, state_updates, :infinity}
  end

  @doc """
  Called by PortHandler when the :gen_tcp socket connection fails.
  Replies error to the original caller and stops the PortHandler.
  """
  def handle_socket_connect_failure(reason, socket_path, caller, state) do
    Logger.error(
      "[InitHandler] Socket connection failed for path '#{socket_path}': #{inspect(reason)}"
    )
    GenServer.reply(caller, {:error, {:init_failed, {:socket_connect_failed, reason}}})

    # Stop the PortHandler
    # Corrected: Merge updates into the received state map
    state_updates = %{
      socket: nil,
      pending_call: nil,
      last_error: {:socket_connect_failed, reason}
      # Consider setting init_stage to :init_failed here?
    }
    final_state = Map.merge(state, state_updates)
    {:stop, {:shutdown, {:socket_connect_failed, reason}}, final_state}
  end


  @doc """
  Called by PortHandler on timeout during initialization stages.
  Replies error to the original caller and stops the PortHandler.
  """
  def handle_timeout_init(stage_atom, state = %{pending_call: {:init, caller}}) do
    Logger.error("[InitHandler] Timeout waiting for #{stage_atom}")
    reason = {:timeout, stage_atom}
    GenServer.reply(caller, {:error, {:init_failed, reason}})
    {:stop, {:shutdown, reason}, state}
  end

  @doc """
  Called by PortHandler when the OS port exits during initialization.
  Replies error to the original caller and stops the PortHandler.
  """
  def handle_port_exit_init(status, state = %{pending_call: {:init, caller}}) do
    Logger.error("[InitHandler] Port process exited during init with status: #{inspect(status)}")
    reason = {:port_exited, status}
    GenServer.reply(caller, {:error, {:init_failed, reason}})
    {:stop, {:shutdown, reason}, state}
  end


  # --- Private Helpers ---

  # Attempt to connect to the socket path received from the port
  # Using :gen_tcp (as :gen_unix is not available)
  # Removed unused default owner argument
  # OBSOLETE: Connection logic moved to ProcessManager.connect_socket
  # defp _attempt_socket_connection(socket_path, timeout_ms) do
    # opts = [:binary, {:active, true}, {:packet, 0}, {:nodelay, true}]
    # # Ensure the path is absolute
    # # absolute_socket_path = Path.expand(socket_path) # Path should already be absolute
    # Logger.debug(
    #   "[InitHandler] Attempting :gen_tcp.connect/4 with path '#{socket_path}' and timeout #{timeout_ms}ms..."
    # )

    # # Using :gen_tcp for UDS - requires path format like {:local, "/path/to/sock"}
    # # Convert string path to charlist for :gen_tcp
    # local_path = {:local, String.to_charlist(socket_path)}
    # case :gen_tcp.connect(local_path, 0, opts, timeout_ms) do
    #   {:ok, socket} ->
    #     Logger.debug(
    #       "[InitHandler] :gen_tcp.connect successful. Socket: #{inspect(socket)}"
    #     )
    #     {:ok, socket}

    #   {:error, reason} ->
    #     Logger.error(
    #       "[InitHandler] Failed :gen_tcp.connect to '#{socket_path}': #{inspect(reason)}"
    #     )
    #     {:error, reason}
    # end
  # end


  # Parses "OK <socket_path>\n" from port output
  defp parse_port_output(<<"OK ", rest :: binary>>) do
    # Find the newline character
    case :binary.split(rest, ["\n"], [:global]) do
      [path_binary, ""] -> # Expect exactly the path and an empty string after the newline
         # Convert path to string, assuming UTF-8 (common for paths)
        path_string = path_binary
                      |> :binary.bin_to_list()
                      |> List.to_string()
        {:ok, path_string}
      _ ->
        Logger.error("[InitHandler] Invalid port output format (no newline or extra data): #{inspect(rest)}")
        {:error, :invalid_format}
    end
  rescue
    e in ArgumentError ->
      Logger.error("[InitHandler] Error converting path binary to string: #{inspect(e)}")
      {:error, :path_encoding_error}
  end

  defp parse_port_output(other) do
    Logger.error("[InitHandler] Unexpected port output format (does not start with 'OK '): #{inspect(other)}")
    {:error, :invalid_format}
  end

end 