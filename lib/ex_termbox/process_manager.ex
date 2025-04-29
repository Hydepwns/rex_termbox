defmodule ExTermbox.ProcessManager do
  require Logger

  @doc """
  Uses Port.open to start the C port process.

  Opts: [:binary, :exit_status, :nouse_stdio]
  - :binary - data is sent/received as binaries
  - :exit_status - receive a message when the port exits
  - :nouse_stdio - prevent port from interacting with group leader stdio
  """
  def spawn_port(command, _args \\ [], opts \\ []) do
    default_opts = [
      # Data as binaries
      :binary,
      # Get exit status message
      :exit_status
    ]

    merged_opts = Keyword.merge(default_opts, opts)

    # Use original command directly
    Logger.debug(
      "ProcessManager: Spawning port process with command: #{command}, opts: #{inspect(merged_opts)}"
    )

    Port.open({:spawn, command}, merged_opts)
  end

  @doc "Uses Port.command to send data to the port process."
  def command_port(port, data) do
    Logger.debug(
      "ProcessManager: Sending command to port #{inspect(port)} (payload length: #{byte_size(data)}): #{inspect(data)}"
    )

    Port.command(port, data)
  end

  @doc "Uses Port.close to close the port."
  def close_port(port) do
    Logger.debug("ProcessManager: Closing port #{inspect(port)}")
    # The process calling close must be the 'connected' process for the port.
    # If PortHandler owns the port, this should be fine.
    Port.close(port)
  end

  @doc "Uses :socket.connect for connecting to the UDS path."
  def connect_socket(path, caller_opts \\ []) do
    # path is expected to be a charlist here (e.g., '/tmp/termbox_test.sock')
    # path_binary = :erlang.list_to_binary(path) # REMOVE conversion to binary
    # :socket address format for local domain
    address = {:local, path} # CHANGE: Use the charlist path directly

    # Translate :gen_tcp style opts to :socket style
    base_opts = [mode: :binary, active: true]
    # Filter out :local if present in caller_opts, as it's handled by the address tuple
    filtered_caller_opts = Keyword.drop(caller_opts, [:local])
    merged_opts = Keyword.merge(base_opts, filtered_caller_opts)

    Logger.debug("ProcessManager: Connecting via :socket to local address: #{inspect(address)} with opts: #{inspect(merged_opts)}")
    # Use :socket.connect with address tuple, port 0, and translated options
    :socket.connect(address, 0, merged_opts)
  end

  @doc "Uses :gen_tcp.send for sending data over the UDS."
  def send_socket(socket, data) do
    Logger.debug("ProcessManager: Sending to socket: #{inspect(data)}")
    :gen_tcp.send(socket, data)
  end

  @doc "Uses :gen_tcp.close for closing the UDS."
  def close_socket(socket) do
    Logger.debug("ProcessManager: Closing socket")
    :gen_tcp.close(socket)
  end
end
