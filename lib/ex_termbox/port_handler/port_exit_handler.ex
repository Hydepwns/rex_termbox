defmodule ExTermbox.PortHandler.PortExitHandler do
  @moduledoc """
  Handles Port exit (`{:EXIT, port, reason}`) messages for `ExTermbox.PortHandler`.
  """
  require Logger
  alias ExTermbox.ProcessManager
  # Alias for function calls
  # alias ExTermbox.PortHandler.InitHandler

  @doc """
  Handles the unexpected termination of the underlying C port process.

  It logs the error, updates the state to reflect the failure, notifies the owner,
  attempts to reply with an error to any pending caller, cleans up the socket,
  and returns a `:stop` tuple for the PortHandler GenServer.
  """
  # Call function in default
  def handle_port_exit(
        status,
        state
      ) do
    Logger.warning(
      "[PortExitHandler] Port process terminated with status: #{status}. Socket: #{inspect(state.socket)}"
    )

    # Close socket if it was open when port exited
    if is_port(state.socket) do
      Logger.info(
        "[PortExitHandler] Closing orphaned socket: #{inspect(state.socket)}"
      )

      # Use ProcessManager or direct :gen_unix call
      ProcessManager.close_socket(state.socket)
    end

    # Update state to indicate failure
    stop_reason = {:port_exited, status}

    # Update the existing state struct instead of creating a plain map
    updated_state = %{state |
      port: nil,
      socket: nil,
      initialized?: false,
      stage: :init_failed,
      pending_call: nil
    }

    # Notify owner
    send(state.owner, {:termbox_error, stop_reason})

    # If there was a pending call, reply with an error
    case state.pending_call do
      {command, from} ->
        Logger.info(
          "[PortExitHandler] Replying error to pending call for command #{command}"
        )

        # Use try/rescue as the caller might have already died or timed out
        try do
          GenServer.reply(from, {:error, stop_reason})
        rescue
          e ->
            Logger.warning(
              "[PortExitHandler] Failed to reply to pending call: #{inspect(e)}"
            )
        end

      nil ->
        :ok
    end

    # Return the stop tuple with the *updated state struct*
    {:stop, stop_reason, updated_state}
  end
end
