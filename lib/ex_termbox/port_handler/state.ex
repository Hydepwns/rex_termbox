defmodule ExTermbox.PortHandler.State do
  @moduledoc """
  Defines the state structure for the ExTermbox.PortHandler GenServer.
  """
  defstruct [
    # The Port process identifier, nil if not started or crashed
    port: nil,
    # The Socket (:gen_tcp socket) for UDS communication, nil if not connected
    socket: nil,
    # The PID of the owner process (usually the process that called start_link)
    owner: nil,
    # The initialization stage (:port_started, :socket_connected, :init_completed)
    stage: :idle,
    # Stage-specific state data (e.g., socket_path during init)
    stage_state: %{},
    # Flag indicating if the port handler initialization sequence is complete
    initialized?: false,
    # Buffer for accumulating data received from the socket
    buffer: <<>>,
    pending_call: nil
  ]

  @type t :: %__MODULE__{
          port: :erlang.port() | nil,
          socket: :inet.socket() | nil,
          owner: pid() | nil,
          stage: :idle | :port_started | :socket_connecting | :socket_connected | :init_completed,
          stage_state: map(),
          initialized?: boolean(),
          buffer: binary(),
          pending_call: {pid(), term()} | nil
        }
end 