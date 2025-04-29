defmodule ExTermbox.PortHandler.TerminationHandler do
  @moduledoc """
  Handles the `terminate/2` callback for `ExTermbox.PortHandler`.
  """
  require Logger
  alias ExTermbox.ProcessManager

  @doc """
  Handles the termination of the PortHandler GenServer.
  Ensures resources like the port and socket are cleaned up.
  Notifies the owner and replies to pending calls on abnormal termination.
  """
  def terminate(reason, state) do
    Logger.info("--- PortHandler terminating --- Reason: #{inspect(reason)}")
    # Ensure socket is closed
    if is_port(state.socket) do
      Logger.debug("Closing socket in terminate: #{inspect(state.socket)}")
      # Don't send shutdown command here, might be terminating due to error
      ProcessManager.close_socket(state.socket)
    end

    # Ensure port is closed
    if not is_nil(state.port) and Port.info(state.port) do
      Logger.debug("Closing port in terminate: #{inspect(state.port)}")
      ProcessManager.close_port(state.port)
    end

    # If terminating abnormally, notify owner and reply to pending call
    if reason != :normal and reason != :shutdown do
      Logger.error(
        "Terminating abnormally. Notifying owner and replying to pending call (if any). Reason: #{inspect(reason)}"
      )

      # Notify owner
      send(state.owner, {:termbox_error, {:handler_terminated, reason}})
      # Reply to pending call
      case state.pending_call do
        {_command, from} ->
          # Use try/rescue as the caller might have already died or timed out
          try do
            GenServer.reply(from, {:error, {:handler_terminated, reason}})
          rescue
            e ->
              Logger.warning(
                "Error replying to pending caller during termination: #{inspect(e)}"
              )
          end

        nil ->
          :ok
      end
    end

    :ok
  end
end
