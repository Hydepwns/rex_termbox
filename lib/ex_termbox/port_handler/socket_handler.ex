defmodule ExTermbox.PortHandler.SocketHandler do
  require Logger
  alias ExTermbox.Buffer
  alias ExTermbox.Protocol
  alias ExTermbox.PortHandler.InitHandler # Alias for function calls

  # --- Public Functions (called by PortHandler) --- 

  # Helper for handle_info({:tcp, socket, data}) when connected
  # Takes data, current buffer, pending_call tuple, owner PID
  # Returns {:noreply, state_updates_map, timeout | nil}
  def handle_socket_data(data, current_buffer, pending_call, owner_pid) do
    # Logger.debug("[SocketHandler] Received TCP data: #{inspect(data)}")

    case Buffer.process(current_buffer, data) do
      {:lines, lines, remaining_buffer} ->
        # Logger.debug(
        #   "[SocketHandler] Buffer processed. Lines: #{inspect(lines)}, Remaining: '#{remaining_buffer}'"
        # )

        # Process lines, updating pending_call
        new_pending_call =
          Enum.reduce(lines, pending_call, fn line, acc_pending_call ->
            process_socket_line(line, acc_pending_call, owner_pid)
          end)

        state_updates = %{
          buffer: remaining_buffer,
          pending_call: new_pending_call
        }
        {:noreply, state_updates, nil}

      {:incomplete, new_buffer} ->
        # Logger.debug("[SocketHandler] Buffer incomplete. New buffer: '#{new_buffer}'")
        {:noreply, %{buffer: new_buffer}, nil}

      other ->
        Logger.error("[SocketHandler] Buffer.process returned unexpected: #{inspect(other)}")
        {:noreply, %{}, nil}
    end
  end

  # Helper for handle_info({:tcp_closed, socket}) when connected
  # Takes pending_call tuple, owner PID
  # Returns {:stop, reason, state_updates_map}
  def handle_socket_closed(pending_call, owner_pid) do
    Logger.warning("[SocketHandler] UDS socket connection closed by C process.")

    stop_reason = :normal
    error_to_reply = :socket_closed

    state_updates = %{
      socket: nil,
      initialized?: false,
      init_stage: InitHandler.init_stage_init_failed(), # Call function
      last_error: error_to_reply,
      pending_call: nil # Clear pending call
    }

    # Notify owner
    send(owner_pid, {:termbox_error, error_to_reply})

    # Reply to pending call if any
    case pending_call do
      {_command, from} -> GenServer.reply(from, {:error, error_to_reply})
      nil -> :ok
    end

    {:stop, stop_reason, state_updates}
  end

  # Helper for handle_info({:tcp_error, socket, reason}) when connected
  # Takes error reason, pending_call tuple, owner PID
  # Returns {:stop, reason, state_updates_map}
  def handle_socket_error(reason, pending_call, owner_pid) do
    Logger.error("[SocketHandler] UDS socket error: #{inspect(reason)}")

    stop_reason = {:socket_error, reason}
    error_to_reply = stop_reason

    state_updates = %{
      socket: nil,
      initialized?: false,
      init_stage: InitHandler.init_stage_init_failed(), # Call function
      last_error: error_to_reply,
      pending_call: nil # Clear pending call
    }

    # Notify owner
    send(owner_pid, {:termbox_error, error_to_reply})

    # Reply to pending call if any
    case pending_call do
      {_command, from} ->
        GenServer.reply(from, {:error, error_to_reply})
      nil ->
        :ok
    end

    {:stop, stop_reason, state_updates}
  end

  # Helper for handle_info(:timeout) when connected
  # Takes command_key, caller PID (from)
  # Returns {:noreply, state_updates_map, timeout | nil}
  def handle_command_timeout(command_key, from) do
    Logger.error(
      "[SocketHandler] Timeout waiting for response for command: #{inspect(command_key)}"
    )

    # Reply timeout error
    GenServer.reply(from, {:error, :command_timeout})

    # Update state: clear pending call
    state_updates = %{pending_call: nil}
    
    # No timeout change needed
    {:noreply, state_updates, nil} 
  end

  # --- Private Helpers (Internal to SocketHandler) --- #

  # Processes a single line from the socket
  # Takes the line, the current pending_call tuple, owner PID
  # Returns the updated pending_call tuple (nil if handled)
  defp process_socket_line(line, current_pending_call, owner_pid) do
    case Protocol.parse_socket_line(line) do
      {:ok_response} ->
        handle_ok_response(current_pending_call)

      {:ok_cell_response, cell_data} ->
        handle_ok_cell_response(cell_data, current_pending_call)

      {:ok_width_response, width} ->
        handle_ok_value_response(:width, width, current_pending_call)

      {:ok_height_response, height} ->
        handle_ok_value_response(:height, height, current_pending_call)

      {:error_response, reason} ->
        handle_error_response(reason, current_pending_call)

      {:event, event_map} ->
        handle_event(event_map, owner_pid, current_pending_call)

      {:parse_error, type, raw_data, reason} ->
        handle_parse_error(type, raw_data, reason, current_pending_call)

      {:unknown_line, raw_line} ->
        handle_unknown_line(raw_line, current_pending_call)

      other ->
        Logger.error("[SocketHandler] Protocol.parse_socket_line unexpected: #{inspect(other)}")
        current_pending_call
    end
  end

  defp handle_ok_response(current_pending_call) do
    case current_pending_call do
      {command_key, from} ->
        # Logger.debug(
        #   "[SocketHandler] OK response for pending cmd: #{inspect(command_key)}"
        # )
        GenServer.reply(from, :ok)
        nil # Clear pending call

      nil ->
        Logger.warning(
          "[SocketHandler] Unexpected OK response (no pending command)."
        )
        nil
    end
  end

  defp handle_ok_cell_response(cell_data, current_pending_call) do
    case current_pending_call do
      {{:get_cell, _x, _y} = command_key, from} ->
        # Logger.debug(
        #   "[SocketHandler] OK_CELL response for pending cmd: #{inspect(command_key)} -> #{inspect(cell_data)}"
        # )
        GenServer.reply(from, {:ok, cell_data})
        nil # Clear pending call

      {other_key, _from} ->
         Logger.warning(
           "[SocketHandler] Received OK_CELL response, but pending call was #{inspect(other_key)}. Ignoring OK_CELL."
         )
         current_pending_call # Keep existing pending call

      nil ->
        Logger.warning(
          "[SocketHandler] Unexpected OK_CELL response (no pending command)."
        )
        nil
    end
  end

  defp handle_ok_value_response(expected_key, value, current_pending_call) do
    case current_pending_call do
      {^expected_key, from} ->
        # Logger.debug(
        #   "[SocketHandler] OK_VALUE response for pending cmd: #{inspect(expected_key)} -> #{inspect(value)}"
        # )
        GenServer.reply(from, {:ok, value})
        nil # Clear pending call

      {other_key, _from} ->
         Logger.warning(
           "[SocketHandler] Received OK_VALUE(#{inspect(expected_key)}) response, but pending call was #{inspect(other_key)}. Ignoring value."
         )
         current_pending_call # Keep existing pending call

      nil ->
        Logger.warning(
          "[SocketHandler] Unexpected OK_VALUE(#{inspect(expected_key)}) response (no pending command)."
        )
        nil
    end
  end

  defp handle_error_response(reason, current_pending_call) do
    case current_pending_call do
      {command_key, from} ->
        Logger.error(
          "[SocketHandler] ERROR response '#{reason}' for pending cmd: #{inspect(command_key)}"
        )
        GenServer.reply(from, {:error, reason})
        nil # Clear pending call

      nil ->
        Logger.error(
          "[SocketHandler] Unexpected ERROR response '#{reason}' (no pending command)."
        )
        nil
    end
  end

  defp handle_event(event_map, owner_pid, current_pending_call) do
    # Logger.info("[SocketHandler] Received Termbox Event: #{inspect(event_map)}") # Keep Info for events
    send(owner_pid, {:termbox_event, event_map})
    current_pending_call # Keep pending call unchanged
  end

  defp handle_parse_error(type, raw_data, reason, current_pending_call) do
    Logger.error(
      "[SocketHandler] Failed to parse socket line (type: #{type}, reason: #{inspect(reason)}). Raw: '#{raw_data}'"
    )
    current_pending_call # Keep pending call unchanged
  end

  defp handle_unknown_line(raw_line, current_pending_call) do
    Logger.warning("[SocketHandler] Received unknown line from socket: '#{raw_line}'")
    current_pending_call # Keep pending call unchanged
  end
end 