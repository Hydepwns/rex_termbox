defmodule ExTermbox.PortHandler.PortExitHandler do
  require Logger
  alias ExTermbox.ProcessManager
  alias ExTermbox.PortHandler.InitHandler # Alias for function calls

  @doc """
  Handles the unexpected termination of the underlying C port process.

  It logs the error, updates the state to reflect the failure, notifies the owner,
  attempts to reply with an error to any pending caller, cleans up the socket,
  and returns a `:stop` tuple for the PortHandler GenServer.
  """
  def handle_port_exit(status, state, _failure_stage \\ InitHandler.init_stage_init_failed()) do # Call function in default
    Logger.warning(
      "[PortExitHandler] Port process terminated with status: #{status}. Socket: #{inspect(state.socket)}"
    )

    # Close socket if it was open when port exited
    if is_port(state.socket) do
      Logger.info("[PortExitHandler] Closing orphaned socket: #{inspect(state.socket)}")
      # Use ProcessManager or direct :gen_tcp call
      ProcessManager.close_socket(state.socket)
    end

    # Update state to indicate failure
    stop_reason = {:port_exited, status}
    state_updates = %{
      port: nil,
      socket: nil, # Also clear socket if port exits
      initialized?: false,
      init_stage: InitHandler.init_stage_init_failed(), # Always fail if port exits - Call function
      last_error: stop_reason,
      pending_call: nil # Clear pending call
    }

    # Notify owner
    send(state.owner, {:termbox_error, stop_reason})

    # If there was a pending call, reply with an error
    case state.pending_call do
      {command, from} ->
        Logger.info("[PortExitHandler] Replying error to pending call for command #{command}")
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

    # Return the stop tuple with the merged state updates
    {:stop, stop_reason, state_updates}
  end
end 