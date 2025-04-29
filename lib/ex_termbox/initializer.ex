defmodule ExTermbox.Initializer do
  @moduledoc """
  Handles the initial setup and supervision of Termbox resources.
  """
  require Logger
  alias ExTermbox.ProcessManager

  # Initialization Stages (mirroring PortHandler for clarity during transition)
  @init_stage_waiting_pty_echo :waiting_pty_echo
  @init_stage_waiting_socket_path :waiting_socket_path
  @init_stage_waiting_initial_ok :waiting_initial_ok
  # No connected stage here, that's handled by PortHandler

  @doc """
  Handles a single line received via PTY during the initialization handshake.

  Takes the line and the current PortHandler state.

  Returns:
  - `{:cont, new_state}`: If the handshake should continue to the next stage.
  - `{:socket_ready, socket, new_state}`: If the handshake is complete and the socket is connected.
  - `{:halt, {:stop, reason, new_state}}`: If the handshake failed irrecoverably.
  """
  def handle_pty_line(line, state = %{init_stage: @init_stage_waiting_pty_echo}) do
    Logger.debug("Initializer: PTY Init Line [Echo]: '#{line}'")

    if line == "init" do
      Logger.debug(
        "Initializer: Ignored echoed 'init' line. Waiting for socket path."
      )

      {:cont, %{state | init_stage: @init_stage_waiting_socket_path}}
    else
      Logger.error(
        "Initializer: Expected echoed 'init' line, but got: '#{line}'. Aborting init."
      )

      error_reason = {:unexpected_pty_line, line}

      # Note: Killing PTY and sending :termbox_init_failed is done by PortHandler
      {:halt, {:stop, error_reason, %{state | init_stage: :failed}}}
    end
  end

  def handle_pty_line(
        line,
        state = %{init_stage: @init_stage_waiting_socket_path}
      ) do
    Logger.debug("Initializer: PTY Init Line [Socket Path]: '#{line}'")

    if String.starts_with?(line, "/") and String.contains?(line, ".sock") do
      Logger.info(
        "Initializer: Received socket path: #{line}. Waiting for initial 'ok'."
      )

      {:cont,
       %{state | socket_path: line, init_stage: @init_stage_waiting_initial_ok}}
    else
      Logger.error(
        "Initializer: Expected socket path line, but got: '#{line}'. Aborting init."
      )

      error_reason = {:invalid_socket_path_line, line}
      {:halt, {:stop, error_reason, %{state | init_stage: :failed}}}
    end
  end

  def handle_pty_line(
        line,
        state = %{
          init_stage: @init_stage_waiting_initial_ok,
          socket_path: socket_path
        }
      ) do
    Logger.debug("Initializer: PTY Init Line [OK Check]: '#{line}'")

    if line == "ok" do
      Logger.info(
        "Initializer: Received initial 'ok' via PTY. Attempting to connect to socket: #{socket_path}"
      )

      case ProcessManager.connect_socket(socket_path) do
        {:ok, socket} ->
          Logger.info(
            "Initializer: Successfully connected to Unix Domain Socket."
          )

          # Handshake complete, socket is ready.
          # Clear buffer in the returned state for socket comms.
          new_state = %{
            state
            | socket: socket,
              initialized?: true,
              init_stage: :connected,
              pending_call: nil,
              buffer: ""
          }

          {:socket_ready, socket, new_state}

        {:error, reason} ->
          Logger.error(
            "Initializer: Failed to connect to Unix Domain Socket #{socket_path}: #{inspect(reason)}"
          )

          error_reason = {:socket_connect_failed, reason}
          {:halt, {:stop, error_reason, %{state | init_stage: :failed}}}
      end
    else
      Logger.error(
        "Initializer: Expected 'ok' line after socket path, but got: '#{line}'. Aborting init."
      )

      error_reason = {:expected_ok_line_missing, line}
      {:halt, {:stop, error_reason, %{state | init_stage: :failed}}}
    end
  end

  # Catch-all for unexpected stages (shouldn't happen if PortHandler guards correctly)
  def handle_pty_line(line, state) do
    Logger.warning(
      "Initializer: handle_pty_line called in unexpected stage [#{state.init_stage}] with line: '#{line}'"
    )

    # Treat as an error
    error_reason = {:unexpected_init_stage, state.init_stage}
    {:halt, {:stop, error_reason, %{state | init_stage: :failed}}}
  end
end
