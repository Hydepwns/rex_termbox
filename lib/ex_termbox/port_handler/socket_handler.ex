defmodule ExTermbox.PortHandler.SocketHandler do
  @moduledoc """
  Handles Unix Domain Socket interactions (`:tcp_*` messages) for `ExTermbox.PortHandler`.
  """
  require Logger
  alias ExTermbox.Buffer
  alias ExTermbox.PortHandler.InitHandler
  alias ExTermbox.Protocol

  # --- Public Functions (called by PortHandler) ---

  # Helper for handle_info({:tcp, socket, data}) when connected
  # Takes data, current buffer, pending_call tuple, owner PID
  # Returns {:noreply, state_updates_map, timeout | nil}
  def handle_socket_data(data, current_buffer, pending_call, owner_pid) do
    # Logger.debug("[SocketHandler] Received TCP data: #{inspect(data)}")
    Logger.debug("[SocketHandler] handle_socket_data received. Buffer: '#{current_buffer}', Data: '#{data}', Pending: #{inspect(pending_call)}")

    result = Buffer.process(current_buffer, data)
    Logger.debug("[SocketHandler] Buffer.process result: #{inspect(result)}")

    case result do
      {:lines, lines, remaining_buffer} ->
        Logger.debug(
          "[SocketHandler] Buffer processed. Lines: #{inspect(lines)}, Remaining: '#{remaining_buffer}'"
        )
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

        # Return :infinity to cancel any pending command timeout
        {:noreply, state_updates, :infinity}

      {:incomplete, new_buffer} ->
        # Logger.debug("[SocketHandler] Buffer incomplete. New buffer: '#{new_buffer}'")
        # Keep existing timeout if buffer is incomplete
        {:noreply, %{buffer: new_buffer}, nil}

      other ->
        Logger.error(
          "[SocketHandler] Buffer.process returned unexpected: #{inspect(other)}"
        )

        {:noreply, %{}, nil}
    end
  end

  # Helper for handle_info({:tcp_closed, socket}) when connected
  # Takes pending_call tuple, owner PID
  # Returns {:stop, reason, state_updates_map}
  def handle_socket_closed(pending_call, owner_pid) do
    Logger.warning("[SocketHandler] UDS socket connection closed by C process.")

    _stop_reason = :normal
    error_to_reply = :socket_closed

    _state_updates = %{
      socket: nil,
      initialized?: false,
      # Call function
      init_stage: InitHandler.init_stage_init_failed(),
      last_error: error_to_reply,
      # Clear pending call
      pending_call: nil
    }

    # Notify owner
    send(owner_pid, {:termbox_error, error_to_reply})

    # Reply to pending call if any
    case pending_call do
      {_command, from} -> GenServer.reply(from, {:error, error_to_reply})
      nil -> :ok
    end

    {:stop, {:shutdown, :c_process_exited}, %{socket: nil, pending_call: nil}}
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
      # Call function
      init_stage: InitHandler.init_stage_init_failed(),
      last_error: error_to_reply,
      # Clear pending call
      pending_call: nil
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
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp process_socket_line(line, current_pending_call, owner_pid) do
    # --- BEGIN REVERT Complexity Refactor ---
    Logger.debug("[SocketHandler] processing line: '#{line}', Pending: #{inspect(current_pending_call)}")

    parse_result = Protocol.parse_socket_line(line)
    Logger.debug("[SocketHandler] Protocol.parse_socket_line result: #{inspect(parse_result)}")

    case parse_result do
      {:ok_response} ->
        handle_ok_response(current_pending_call)

      {:ok_cell_response, cell_data} ->
        handle_ok_cell_response(cell_data, current_pending_call)

      # Revert width/height combination
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
        Logger.error(
          "[SocketHandler] Protocol.parse_socket_line unexpected: #{inspect(other)}"
        )

        current_pending_call
    end

    # --- END REVERT Complexity Refactor ---
  end

  defp handle_ok_response(current_pending_call) do
    case current_pending_call do
      {command_key, from} ->
        Logger.debug(
          "[SocketHandler] Replying :ok to #{inspect(from)} for cmd: #{inspect(command_key)}"
        )
        GenServer.reply(from, :ok)
        # Clear pending call
        nil

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
        Logger.debug(
          "[SocketHandler] Replying {:ok, cell_data} to #{inspect(from)} for cmd: #{inspect(command_key)}"
        )
        GenServer.reply(from, {:ok, cell_data})
        # Clear pending call
        nil

      {other_key, _from} ->
        Logger.warning(
          "[SocketHandler] Received OK_CELL response, but pending call was #{inspect(other_key)}. Ignoring OK_CELL."
        )

        # Keep existing pending call
        current_pending_call

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
        Logger.debug(
          "[SocketHandler] Replying {:ok, #{inspect(value)}} to #{inspect(from)} for cmd: :#{expected_key}"
        )
        GenServer.reply(from, {:ok, value})
        # Clear pending call
        nil

      {other_key, _from} ->
        Logger.warning(
          "[SocketHandler] Received OK_VALUE(#{inspect(expected_key)}) response, but pending call was #{inspect(other_key)}. Ignoring value."
        )

        # Keep existing pending call
        current_pending_call

      nil ->
        Logger.warning(
          "[SocketHandler] Unexpected OK_VALUE(#{inspect(expected_key)}) response (no pending command)."
        )

        nil
    end
  end

  defp handle_error_response(reason, current_pending_call) do
    case current_pending_call do
      {_command_key, from} ->
        Logger.error(
          "[SocketHandler] ERROR response '#{reason}' for pending cmd"
        )

        GenServer.reply(from, {:error, reason})
        # Clear pending call
        nil

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
    # Keep pending call unchanged
    current_pending_call
  end

  defp handle_parse_error(type, raw_data, reason, current_pending_call) do
    Logger.error(
      "[SocketHandler] Failed to parse socket line (type: #{type}, reason: #{inspect(reason)}). Raw: '#{raw_data}'"
    )

    # Keep pending call unchanged
    current_pending_call
  end

  defp handle_unknown_line(raw_line, current_pending_call) do
    Logger.warning(
      "[SocketHandler] Received unknown line from socket: '#{raw_line}'"
    )

    # Keep pending call unchanged
    current_pending_call
  end

  # --- Cleanup ---

end
