defmodule ExTermbox.PortHandler.CallHandler do
  @moduledoc """
  Handles `handle_call/3` callbacks and logic for `ExTermbox.PortHandler`.
  """
  require Logger
  alias ExTermbox.ProcessManager
  # Alias for function calls
  alias ExTermbox.PortHandler.InitHandler
  # Add alias for protocol
  alias ExTermbox.Protocol

  # --- Public Functions (called by PortHandler) --- #

  # Handles calls received when the PortHandler is not yet fully connected.
  def handle_call_when_not_connected(call_msg, stage, state) do
    # e.g., :command, :get_cell
    command_key = elem(call_msg, 0)

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
          # Call function
          init_stage: InitHandler.init_stage_init_failed(),
          last_error: stop_reason,
          # Clear pending call on error
          pending_call: nil
        }

        # Reply error before stopping
        GenServer.reply(from, {:error, stop_reason})
        {:stop, stop_reason, state_updates}
    end
  end

  # Handles standard commands like print, clear, present
  # These currently expect just an :ok or :error response
  # Refactored: Takes command_key and command_string directly
  def handle_simple_command(command_key, command_string, from, state) do
    # command_string = command_fun.() # Removed - String passed directly
    Logger.debug("[CallHandler] Handling simple command [#{inspect(command_key)}]: #{inspect(command_string)}")

    case state.socket do
      nil ->
        Logger.error(
          "[CallHandler] Cannot send command '#{command_string}', socket is nil."
        )

        GenServer.reply(from, {:error, :not_initialized})
        {:noreply, state}

      socket ->
        Logger.debug("[CallHandler] Sending simple command '#{command_string}' to socket.")
        # Append newline if not already present? Protocol functions should handle this.
        case ProcessManager.send_socket(socket, command_string) do # Assuming Protocol adds newline
          :ok ->
            # Store the pending call using command_key
            new_state = %{
              state
              # Tag pending call just with command_key for simplicity?
              # Or use {command_key, command_string} if string is needed?
              | pending_call: {command_key, from} # Simplified pending call tag
            }

            # Start timeout waiting for C response - state.timeout doesn't exist!
            # Use a default or configurable timeout.
            default_timeout = 5000 # ms
            {:noreply, new_state, default_timeout}

          {:error, reason} ->
            Logger.error(
              "[CallHandler] Socket send failed for [#{inspect(command_key)}]: #{inspect(reason)}"
            )

            stop_reason = {:socket_send_failed, reason}

            # Use struct update syntax and correct stage atom
            new_state = %{state |
              socket: nil,
              initialized?: false,
              stage: :init_failed, # Use atom
              # last_error: stop_reason, # No last_error field
              pending_call: nil
            }

            # Reply error before stopping
            GenServer.reply(from, {:error, stop_reason})
            {:stop, stop_reason, new_state}
        end
    end
  end

  # Handles the special :trigger_poll_event call.
  # Takes the socket reference.
  # Returns {:reply, :ok | error_tuple, state_updates}
  def handle_trigger_poll_event(state) do
    case state.socket do
      nil ->
        Logger.error("[CallHandler] Cannot trigger poll event, socket is nil.")
        {:noreply, state}

      socket ->
        # Logger.debug("[CallHandler] Triggering event poll.")
        # C side command TBD, assuming "POLL_EVENT" for now
        # No reply expected, so no pending_call update
        case ProcessManager.send_socket(socket, "POLL_EVENT\n") do
          :ok ->
            # Do nothing, just sent the command
            :ok

          {:error, reason} ->
            Logger.error(
              "[CallHandler] Socket send failed for poll_event: #{inspect(reason)}"
            )

            # Update state to reflect potential issue
            state_updates = %{
              # We don't know for sure the socket is dead, but log it.
              last_error: {:poll_event_send_failed, reason}
            }

            {:reply, {:error, {:socket_send_failed, reason}}, state_updates}
        end
    end
  end

  # Handles the :request_port_close call for shutdown.
  # Takes the socket reference and port reference.
  # Returns {:reply, :ok, state_updates_map}
  def handle_request_port_close(state) do
    case state.port do
      nil ->
        Logger.info("[CallHandler] Port already closed or nil.")
        {:noreply, state}

      port ->
        Logger.info("[CallHandler] Requesting port close.")
        # TODO: Consider sending a clean shutdown command via socket first?
        # For now, just close the port directly.
        case ProcessManager.close_port(port) do
          # Port.close returns true on success
          true ->
            # Port closed, don't clear it yet, wait for :port_exit
            Logger.debug("[CallHandler] Port closed command sent successfully. Stopping GenServer.")
            # Stop the GenServer
            {:stop, :shutdown, state}

          # If Port.close could theoretically fail and return something else?
          # The docs say it always returns true, but let's be safe.
          other ->
            Logger.error(
              "[CallHandler] ProcessManager.close_port returned unexpected value: #{inspect(other)}. Treating as failure."
            )

            # Should we stop? For now, just log and continue.
            {:noreply, state}
        end
    end
  end

  # Handles the {:get_cell, x, y} call.
  def handle_get_cell(x, y, from, state) do
    command_string = Protocol.format_get_cell_command(x, y)

    case state.socket do
      nil ->
        Logger.error("[CallHandler] Cannot get_cell, socket is nil.")
        GenServer.reply(from, {:error, :not_initialized})
        {:noreply, state}

      socket ->
        # Logger.debug("[CallHandler] Sending get_cell command for (#{x}, #{y}).")
        case ProcessManager.send_socket(socket, command_string <> "\n") do
          :ok ->
            # Store the pending call
            new_state = %{state | pending_call: {{:get_cell, x, y}, from}}
            # Start timeout waiting for C response
            {:noreply, new_state, state.timeout}

          {:error, reason} ->
            Logger.error(
              "[CallHandler] Socket send failed for [#{inspect({:get_cell, x, y})}]: #{inspect(reason)}"
            )

            stop_reason = {:socket_send_failed, reason}

            new_state = %{
              socket: nil,
              initialized?: false,
              # Call function
              init_stage: InitHandler.init_stage_init_failed(),
              last_error: stop_reason,
              # Clear pending call on error
              pending_call: nil
            }

            # Reply error before stopping
            GenServer.reply(from, {:error, stop_reason})
            {:stop, stop_reason, new_state}
        end
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

  # Handles the :select_input_mode call.
  # REMOVE - This seems overly specific, handled by handle_call in PortHandler now?
  # Let's verify handle_call in PortHandler for :select_input_mode
  # It calls ExTermbox.select_input_mode which sends {:command, :set_input_mode, payload}
  # This will be routed to handle_simple_command via handle_call in PortHandler
  # So, this specific handle_select_input_mode function in CallHandler is likely dead code.

  # Let's comment it out for now.
  # def handle_select_input_mode(mode, command_key, from, state) do
  #   # Use Protocol module to format the command
  #   command_string = Protocol.format_set_input_mode_command(mode)
  #   # Use simple command helper - Pass key and formatted string
  #   handle_simple_command(command_key, command_string, from, state)
  # end

  # Handles the :set_cursor call.
  def handle_set_cursor(x, y, from, state) do
    command_string = Protocol.format_set_cursor_command(x, y)
    command_key = :set_cursor
    # Use simple command as it just expects OK
    handle_simple_command(command_key, command_string, from, state)
  end

  # --- Private Helpers for individual commands ---
end
