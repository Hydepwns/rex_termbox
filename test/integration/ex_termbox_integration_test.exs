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
        # Use on_exit to ensure the PortHandler is killed even if the test fails
        on_exit(context, fn ->
          # Don't rely on clean shutdown API in test teardown, as it seems racy.
          # Just ensure the process is stopped.
          # _ = ExTermbox.shutdown(pid)
          # Process.sleep(50)
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
        # Compare against the *integer* values from Constants
        assert cell_data.fg == ExTermbox.Constants.color(fg)
        assert cell_data.bg == ExTermbox.Constants.color(bg)

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
    assert ExTermbox.set_output_mode(context.handler_pid, :term_256) == :ok
    assert ExTermbox.set_output_mode(context.handler_pid, :grayscale) == :ok
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

    # Create a sample event (e.g., Arrow Up key press)
    test_event_map = %{
      type: :key,
      mod: ExTermbox.Constants.mod(:none), # Use the integer value
      key: ExTermbox.Constants.key(:arrow_up),
      ch: 0,
      w: 0, h: 0, x: 0, y: 0
    }

    # Call the function with individual arguments
    assert ExTermbox.debug_send_event(
      context.handler_pid,
      :key,
      :none,
      :arrow_up,
      test_event_map.ch,
      test_event_map.w,
      test_event_map.h,
      test_event_map.x,
      test_event_map.y
    ) == :ok

    # Assert that the event is received by the owner process
    assert_receive {:termbox_event, received_event} # Basic check
    # More specific check (convert received map keys if necessary)
    assert received_event.type == test_event_map.type
    assert received_event.mod == test_event_map.mod
    assert received_event.key == test_event_map.key
  end

  test "handles C process crash gracefully", context do
    # Trap exits so the test doesn't die when the linked handler crashes
    Process.flag(:trap_exit, true)

    {:ok, handler_pid} = ExTermbox.init(owner: self())

    # Monitor the handler process
    ref = Process.monitor(handler_pid)

    # Send the crash command. Expect an error because the C process exits immediately.
    # The command might be sent successfully, but the socket closes before reply.
    assert ExTermbox.debug_crash(handler_pid) in [:ok, {:error, :socket_closed}]

    # Wait for the handler to go down because the C process crashed
    assert_receive {:DOWN, ^ref, :process, ^handler_pid, {:shutdown, :c_process_exited}}

    # Verify the handler PID is actually dead
    # Use Process.sleep to give BEAM time to fully cleanup the process entry
    Process.sleep(50)
    refute Process.alive?(handler_pid)

    # Ensure subsequent calls return :noproc
    assert ExTermbox.present(handler_pid) == {:error, :noproc}
    assert ExTermbox.width(handler_pid) == {:error, :noproc}
  end

  # TODO: Add more tests, e.g., for specific cell changes (if possible), events
end
