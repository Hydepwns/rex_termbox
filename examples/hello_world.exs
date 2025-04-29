# This is a simple terminal application to show how to get started.
#
# To run this file:
#
#    mix run examples/hello_world.exs

alias ExTermbox

defmodule HelloWorld do
  def run do
    # Start ExTermbox, registering the current process to receive events
    # Use keyword list for options, including owner: self()
    # Use a unique name if you want to manage multiple instances
    opts = [owner: self()] # Removed name: MyTermboxInstance for simplicity in example
    case ExTermbox.init(opts) do
      {:ok, _pid} -> # PID is managed internally now, init returns :ok or {:error, _}
        IO.puts("ExTermbox initialized successfully.")
        # Clear the screen
        :ok = ExTermbox.clear()

        # Print "Hello, World!" at (0, 0) with default colors
        :ok = ExTermbox.print(0, 0, :default, :default, "Hello, World!")

        # Print "(Press <q> to quit)" at (0, 2)
        :ok = ExTermbox.print(0, 2, :default, :default, "(Press <q> to quit)")

        # Render the changes to the terminal
        :ok = ExTermbox.present()

        # Wait for the 'q' key event
        wait_for_quit()

        # Shut down ExTermbox
        # Shutdown no longer takes a PID argument
        :ok = ExTermbox.shutdown()
        IO.puts("ExTermbox shut down.")

      {:error, reason} ->
        IO.inspect(reason, label: "Error initializing ExTermbox")
    end
  end

  defp wait_for_quit do
    receive do
      # Events are sent as messages to the registered process (owner passed to init)
      {:termbox_event, %{type: :key, key: :q}} ->
        :quit # Just return, shutdown happens after run/0 returns
      {:termbox_event, %{type: :key, key: :"C-c"}} -> # Handle Ctrl+C gracefully
        IO.puts("\nCtrl+C received, exiting.")
        :quit
      {:termbox_event, event} ->
        # IO.inspect(event, label: "Received event") # Uncomment to see other events
        wait_for_quit() # Wait for the next event
      other_message ->
        # IO.inspect(other_message, label: "Received other message") # Keep for debugging non-termbox messages
        wait_for_quit() # Wait for the next event
    after
      30_000 -> IO.puts("Timeout waiting for 'q' key or Ctrl+C.") # Increase timeout slightly
    end
  end
end

# The owner process needs to stay alive to receive messages.
# HelloWorld.run() will block until wait_for_quit returns.
HelloWorld.run()

# Explicit exit might be needed if run via certain contexts, but
# usually the script termination after run/0 finishes is sufficient.
# System.halt(0)
