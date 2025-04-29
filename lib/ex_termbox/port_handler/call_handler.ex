defmodule ExTermbox.PortHandler.CallHandler do
  require Logger
  alias ExTermbox.ProcessManager
  alias ExTermbox.PortHandler.InitHandler # Alias for function calls
  alias ExTermbox.Protocol # Add alias for protocol

  # --- Public Functions (called by PortHandler) --- #

  # Handles calls received when the PortHandler is not yet fully connected.
  def handle_call_when_not_connected(call_msg, stage, state) do
    command_key = elem(call_msg, 0) # e.g., :command, :get_cell
    Logger.warning(
      "[CallHandler] Received command '#{inspect(command_key)}' while PortHandler not connected (stage: #{stage}). Replying :not_initialized."
    )
    {:reply, {:error, :not_initialized}, state}
  end

  # Generic function to handle sending a command that expects a reply
  defp handle_sync_command(command_key, command_string, from, socket, timeout) do
    Logger.debug(
      "[CallHandler] Sending sync command [#{inspect(command_key)}] '#{command_string}' via socket..."
    )

    case ProcessManager.send_socket(socket, command_string <> "\n") do
      :ok ->
        Logger.debug(
          "[CallHandler] Socket send OK for [#{inspect(command_key)}]. Storing pending call."
        )
        # Update state to store pending call
        state_updates = %{pending_call: {command_key, from}}
        {:noreply, state_updates, timeout}

      {:error, reason} ->
        Logger.error(
          "[CallHandler] Socket send failed for [#{inspect(command_key)}]: #{inspect(reason)}"
        )
        stop_reason = {:socket_send_failed, reason}
        state_updates = %{
          socket: nil,
          initialized?: false,
          init_stage: InitHandler.init_stage_init_failed(), # Call function
          last_error: stop_reason,
          pending_call: nil # Clear pending call on error
        }
        # Reply error before stopping
        GenServer.reply(from, {:error, stop_reason})
        {:stop, stop_reason, state_updates}
    end
  end

  # Handles standard commands like print, clear, present
  # These currently expect just an :ok or :error response
  def handle_simple_command(command_key, command_string, from, socket, timeout) do
    # Logger.debug(
    #  "[CallHandler] Sending simple command: Key=#{inspect(command_key)}, Str='#{command_string}'"
    # )

    case ProcessManager.send_socket_command(socket, command_string) do
      :ok ->
        state_updates = %{pending_call: {command_key, from}}
        # Start timeout waiting for C response
        {:noreply, state_updates, timeout}

      {:error, reason} ->
        Logger.error(
          "[CallHandler] Socket send failed for [#{inspect(command_key)}]: #{inspect(reason)}"
        )
        stop_reason = {:socket_send_failed, reason}
        state_updates = %{
          socket: nil,
          initialized?: false,
          init_stage: InitHandler.init_stage_init_failed(), # Call function
          last_error: stop_reason,
          pending_call: nil # Clear pending call on error
        }
        # Reply error before stopping
        GenServer.reply(from, {:error, stop_reason})
        {:stop, stop_reason, state_updates}
    end
  end

  # Handles the special :trigger_poll_event call.
  # Takes the socket reference.
  # Returns {:reply, :ok | error_tuple, state_updates}
  def handle_trigger_poll_event(socket) do
    command_str = "poll_event"
    # Logger.debug("[CallHandler] Sending poll_event command.")

    case ProcessManager.send_socket_command(socket, command_str) do
      :ok ->
        # Reply immediately, C process handles blocking poll
        Logger.debug("[CallHandler] Socket send successful for poll_event.")
        # No state change needed, just reply ok
        {:reply, :ok, %{}}

      {:error, reason} ->
        Logger.error("[CallHandler] Socket send failed for poll_event: #{inspect(reason)}")
        # Don't stop the GenServer here, just return the error
        # Update state to reflect potential issue
        state_updates = %{
          # We don't know for sure the socket is dead, but log it.
          last_error: {:poll_event_send_failed, reason}
        }
        {:reply, {:error, {:socket_send_failed, reason}}, state_updates}
    end
  end

  # Handles the :request_port_close call for shutdown.
  # Takes the socket reference and port reference.
  # Returns {:reply, :ok, state_updates_map}
  def handle_request_port_close(socket, port) do
    # Logger.debug("[CallHandler] Handling :request_port_close.")

    # 1. Send shutdown command via socket if connected
    if is_port(socket) do
      # Logger.debug("[CallHandler] Sending shutdown command via socket.")
      # Best effort, ignore result
      ProcessManager.send_socket_command(socket, "shutdown")
    else
      # Logger.debug("[CallHandler] Socket not connected, skipping shutdown command.")
      :ok
    end

    # 2. Close the original Elixir Port
    if is_port(port) do
      # Logger.debug("[CallHandler] Closing Elixir Port: #{inspect(port)}.")
      ProcessManager.close_port(port)
    else
      # Logger.debug("[CallHandler] Elixir Port already closed or nil.")
      :ok
    end

    # 3. Reply OK and update state (PortHandler will change to noreply)
    # Logger.debug("[CallHandler] Replying :ok for request_port_close.")
    {:reply, :ok, %{}}
  end

  # Handles the {:get_cell, x, y} call.
  def handle_get_cell(x, y, from, socket, timeout) do
    command_key = {:get_cell, x, y}
    command_str = Protocol.format_get_cell_command(x, y)
    # Logger.debug("[CallHandler] Sending get_cell command: Str='#{command_str}'")

    case ProcessManager.send_socket_command(socket, command_str) do
      :ok ->
        state_updates = %{pending_call: {command_key, from}}
        # Start timeout waiting for C response
        {:noreply, state_updates, timeout}

      {:error, reason} ->
        Logger.error(
          "[CallHandler] Socket send failed for [#{inspect(command_key)}]: #{inspect(reason)}"
        )
        stop_reason = {:socket_send_failed, reason}
        state_updates = %{
          socket: nil,
          initialized?: false,
          init_stage: InitHandler.init_stage_init_failed(), # Call function
          last_error: stop_reason,
          pending_call: nil # Clear pending call on error
        }
        # Reply error before stopping
        GenServer.reply(from, {:error, stop_reason})
        {:stop, stop_reason, state_updates}
    end
  end

  # Handles the :width call.
  def handle_width(from, socket, timeout) do
    command_string = Protocol.format_width_command()
    command_key = :width
    handle_sync_command(command_key, command_string, from, socket, timeout)
  end

  # Handles the :height call.
  def handle_height(from, socket, timeout) do
    command_string = Protocol.format_height_command()
    command_key = :height
    handle_sync_command(command_key, command_string, from, socket, timeout)
  end

  # Handles the :set_cursor call.
  def handle_set_cursor(x, y, from, socket, timeout) do
    command_string = Protocol.format_set_cursor_command(x, y)
    command_key = :set_cursor
    # Use simple command as it just expects OK
    handle_simple_command(command_key, command_string, from, socket, timeout)
  end

end 