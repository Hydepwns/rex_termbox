defmodule ExTermbox.ProcessManager do
require Logger

@moduledoc """
Manages the lifecycle of the C helper process and the PortHandler GenServer.

Provides functions to:
- Spawn the Port process (`spawn_port_process/2`)
- Connect to the socket exposed by the C helper (`connect_socket/1`)
- Send commands to the C helper via the Port (`send_command_to_port/2`)
- Manage the socket connection (`manage_socket_connection/1`)
"""

@default_connect_timeout 5000 # Default timeout for socket connection in ms

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

  # Port.open returns the port on success or raises on error.
  # We need to catch potential errors and return {:error, reason}.
  try do
    port = Port.open({:spawn, command}, merged_opts)
    {:ok, port}
  rescue
    e in ErlangError ->
      Logger.error("ProcessManager: Failed to spawn port process: #{inspect(e)}")
      {:error, e}
  end
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

@doc """
Connects to a Unix Domain Socket at the given path.
"""
@spec connect_socket(Path.t(), pos_integer()) :: {:ok, :socket.socket()} | {:error, any()}
def connect_socket(path, timeout \\ @default_connect_timeout) do
  # Convert path charlist (e.g., ~c"/tmp/socket.sock") to binary for :gen_tcp
  binary_path = to_string(path)
  address = {:local, binary_path}
  # Options: Use local domain, binary mode, passive (active: false)
  opts = [:local, :binary, active: false]

  Logger.debug("ProcessManager: Attempting to connect to UDS #{inspect(binary_path)} with timeout #{timeout}ms using :gen_tcp")

  # Use :gen_tcp.connect for UDS
  case :gen_tcp.connect(address, 0, opts, timeout) do
    {:ok, socket} ->
      Logger.info("Socket connected successfully via :gen_tcp to #{inspect(binary_path)}")
      # The socket returned by gen_tcp should already be configured based on opts.
      {:ok, socket}

    {:error, reason} ->
      Logger.error("Failed to connect socket via :gen_tcp to #{inspect(binary_path)}: #{inspect(reason)}")
      # No socket descriptor to close if connect fails
      {:error, {:connect_failed, reason}}
  end
end

@doc "Uses :socket.send for sending data over the UDS."
def send_socket(socket, data) do
  Logger.debug(
    "ProcessManager: Sending to socket (via :socket.send): #{inspect(data)}"
  )

  # Use :socket.send which works with sockets from :socket.connect for TCP/UDS
  :socket.send(socket, data)
end

@doc "Uses :gen_tcp.close for closing the UDS created via :gen_tcp."
def close_socket(socket) do
  Logger.debug("ProcessManager: Closing socket (using :gen_tcp)")
  # Use :gen_tcp.close for sockets opened via :gen_tcp
  :gen_tcp.close(socket)
end

end
