defmodule ExTermbox.IntegrationTest do
  # Integration tests often need to run sequentially
  use ExUnit.Case, async: false

  # Tag to exclude from normal `mix test` runs unless explicitly included
  # or run via `mix test --include integration`
  @moduletag :integration

  setup context do
    # Start the ExTermbox supervised process using the public API
    # Start without a name for test isolation
    case ExTermbox.init([]) do
      {:ok, pid} ->
        # No longer need sleep, init is synchronous
        # Process.sleep(1000)

        # Use shutdown on exit, targeting the specific PID
        on_exit(context, fn ->
          # Attempt clean shutdown via API first
          _ = ExTermbox.shutdown(pid)
          # Ensure process is stopped even if shutdown fails
          # Use Process.exit with :kill for immediate termination if still alive
          if Process.alive?(pid), do: Process.exit(pid, :kill)
        end)

        # Setup successful, return pid in context
        {:ok, %{handler_pid: pid}}

      {:error, reason} ->
        # Fail the setup if init fails
        {:error, %{reason: reason}}
    end
  end

  test "initializes, presents, and clears without error", context do
    # Remove sleep, init is sync
    # Process.sleep(500)

    # Pass handler_pid from context
    assert ExTermbox.present(context.handler_pid) == :ok
    assert ExTermbox.clear(context.handler_pid) == :ok
    assert ExTermbox.present(context.handler_pid) == :ok
  end

  test "prints text and verifies content via get_cell", context do
    # Remove sleep
    # Process.sleep(500)

    # Check if the print call succeeds
    char_to_print = "H"
    x_pos = 1
    y_pos = 1
    # Use atoms for colors
    fg = :red
    bg = :blue
    text = char_to_print <> "ello Integration Test"

    # Pass handler_pid
    assert ExTermbox.print(context.handler_pid, x_pos, y_pos, fg, bg, text) == :ok

    # Present the changes (important!)
    # Pass handler_pid
    assert ExTermbox.present(context.handler_pid) == :ok

    # Allow a very brief moment for C side to process/update
    Process.sleep(50)

    # Get the cell content back
    # Pass handler_pid
    case ExTermbox.get_cell(context.handler_pid, x_pos, y_pos) do
      {:ok, cell_data} ->
        # Assert on the map contents
        assert cell_data.x == x_pos
        assert cell_data.y == y_pos
        # Check against the character we actually printed
        assert cell_data.char == char_to_print
        # Assume get_cell also returns atoms now
        assert cell_data.fg == fg
        assert cell_data.bg == bg

      {:error, reason} ->
        flunk("get_cell failed: #{inspect(reason)}")
    end
  end

  test "gets width and height", context do
    # Remove sleep
    # Process.sleep(500)

    # Get width
    # Pass handler_pid
    case ExTermbox.width(context.handler_pid) do
      {:ok, width} ->
        assert is_integer(width) and width > 0
      {:error, reason} ->
        flunk("width() failed: #{inspect(reason)}")
    end

    # Get height
    # Pass handler_pid
    case ExTermbox.height(context.handler_pid) do
      {:ok, height} ->
        assert is_integer(height) and height > 0
      {:error, reason} ->
        flunk("height() failed: #{inspect(reason)}")
    end
  end

  test "sets cursor position", context do
    # Remove sleep
    # Process.sleep(500)

    # Pass handler_pid
    assert ExTermbox.set_cursor(context.handler_pid, 5, 10) == :ok
    assert ExTermbox.present(context.handler_pid) == :ok

    # Hide the cursor
    # Pass handler_pid
    assert ExTermbox.set_cursor(context.handler_pid, -1, -1) == :ok
    assert ExTermbox.present(context.handler_pid) == :ok
  end

  test "sets input mode", context do
    # Remove sleep
    # Process.sleep(500)

    # Pass handler_pid
    # Test setting individual modes using atoms
    assert ExTermbox.select_input_mode(context.handler_pid, :esc) == :ok
    assert ExTermbox.select_input_mode(context.handler_pid, :alt) == :ok

    # Pass handler_pid
    # The API currently takes one mode at a time, bitwise combination via API isn't directly supported
    # mode_combined = Bitwise.bor(mode_esc, mode_alt) # Removed
    # assert ExTermbox.select_input_mode(context.handler_pid, mode_combined) == :ok # Removed

    # Pass handler_pid
    # Use atom for current mode
    assert ExTermbox.select_input_mode(context.handler_pid, :current) == :ok
  end

  test "sets output mode", context do
    # Remove sleep
    # Process.sleep(500)

    # Pass handler_pid
    # Use atoms for output modes
    assert ExTermbox.set_output_mode(context.handler_pid, :normal) == :ok
    assert ExTermbox.set_output_mode(context.handler_pid, :truecolor) == :ok
    assert ExTermbox.set_output_mode(context.handler_pid, :c256) == :ok
    assert ExTermbox.set_output_mode(context.handler_pid, :current) == :ok

    # Pass handler_pid
    assert ExTermbox.present(context.handler_pid) == :ok
  end

  test "sets clear attributes", context do
    # Remove sleep
    # Process.sleep(500)

    # Use atoms for colors
    fg = :yellow
    bg = :magenta

    # Pass handler_pid
    assert ExTermbox.set_clear_attributes(context.handler_pid, fg, bg) == :ok

    # Pass handler_pid
    assert ExTermbox.clear(context.handler_pid) == :ok
    assert ExTermbox.present(context.handler_pid) == :ok

    # Pass handler_pid
    assert ExTermbox.set_clear_attributes(
             context.handler_pid,
             # Use atom for default color
             :default,
             :default
           ) == :ok

    # Pass handler_pid
    assert ExTermbox.clear(context.handler_pid) == :ok
    assert ExTermbox.present(context.handler_pid) == :ok
  end

  test "receives synthetic event via debug command", context do
    # Remove sleep
    # Process.sleep(500)

    # Subscribe the test process to events from the specific handler
    # We need an `EventManager.subscribe(pid_or_name)` function
    # Assuming EventManager also uses PID now, or we modify it.
    # Let's assume for now EventManager needs adjustment too, but
    # we first make sure the event command can be SENT.

    # Define the event using atoms
    test_event = %{
      type: :key, # Use atom
      mod: 0,
      key: :arrow_up, # Use atom
      ch: 0,
      w: 0, h: 0, x: 0, y: 0
    }

    # Send the debug command, passing handler_pid
    assert ExTermbox.debug_send_event(context.handler_pid, test_event) == :ok

    # Need mechanism to receive event
    # Assuming events are sent to the owner (test process)
    # Add `allow_subscribe_from_self: true` to init maybe?
    # Or refactor EventManager...
    # For now, just assert the command was sent.
    # We'll need to verify reception later.
    assert_receive {:termbox_event, ^test_event}, 500 # Add timeout

  end

  # TODO: Add more tests, e.g., for specific cell changes (if possible), events
end
