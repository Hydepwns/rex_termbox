defmodule ExTermbox.IntegrationTest do
  use ExUnit.Case, async: false # Integration tests often need to run sequentially

  # Tag to exclude from normal `mix test` runs unless explicitly included
  # or run via `mix test --include integration`
  @moduletag :integration

  setup do
    # Start the ExTermbox supervised process using the public API
    case ExTermbox.init([]) do
      {:ok, _pid} ->
        # Give the port/socket a moment to initialize fully
        Process.sleep(1000) # Increased delay
        # Use shutdown on exit
        on_exit(fn -> ExTermbox.shutdown() end)
        :ok # Setup successful
      {:error, reason} ->
         # Fail the setup if init fails
         {:error, %{reason: reason}}
    end
  end

  test "initializes, presents, and clears without error" do
    # Add a sleep here to ensure PortHandler processes the init message
    Process.sleep(500)

    # Simple check to ensure the process starts and basic commands don't crash
    # We can't easily verify the *visual* output in an automated test,
    # but we can check if the calls succeed.
    # Use public API without pid
    assert ExTermbox.present() == :ok
    assert ExTermbox.clear() == :ok
    assert ExTermbox.present() == :ok
  end

  test "prints text and verifies content via get_cell" do
    # Add a sleep here to ensure PortHandler processes the init message
    Process.sleep(500)

    # Check if the print call succeeds
    char_to_print = "H"
    x_pos = 1
    y_pos = 1
    # Use constants if available, otherwise raw integers
    fg = ExTermbox.Const.Color.RED
    bg = ExTermbox.Const.Color.BLUE
    text = char_to_print <> "ello Integration Test"
    # Use public API without pid
    assert ExTermbox.print(x_pos, y_pos, fg, bg, text) == :ok

    # Present the changes (important!)
    # Use public API without pid
    assert ExTermbox.present() == :ok

    # Allow a very brief moment for C side to process/update
    Process.sleep(50)

    # Get the cell content back
    # Use public API without pid
    case ExTermbox.get_cell(x_pos, y_pos) do
      {:ok, cell_data} ->
        # Assert on the map contents
        assert cell_data.x == x_pos
        assert cell_data.y == y_pos
        # Check against the character we actually printed
        assert cell_data.char == char_to_print
        assert cell_data.fg == fg
        assert cell_data.bg == bg

      {:error, reason} ->
        flunk("get_cell failed: #{inspect(reason)}")
    end

  end

  test "gets width and height" do
    # Add a sleep here to ensure PortHandler processes the init message
    Process.sleep(500)

    # Get width
    case ExTermbox.width() do
      {:ok, width} ->
        # We don't know the exact width, but it should be a positive integer
        assert is_integer(width) and width > 0

      {:error, reason} ->
        flunk("width() failed: #{inspect(reason)}")
    end

    # Get height
    case ExTermbox.height() do
      {:ok, height} ->
        # We don't know the exact height, but it should be a positive integer
        assert is_integer(height) and height > 0

      {:error, reason} ->
        flunk("height() failed: #{inspect(reason)}")
    end
  end

  test "sets cursor position" do
    # Add a sleep here to ensure PortHandler processes the init message
    Process.sleep(500)

    # Set cursor to a position (e.g., 5, 10)
    assert ExTermbox.set_cursor(5, 10) == :ok
    # We need to present to see the effect, but we can't verify visually easily.
    assert ExTermbox.present() == :ok 

    # Hide the cursor
    assert ExTermbox.set_cursor(-1, -1) == :ok
    assert ExTermbox.present() == :ok
  end

  test "sets input mode" do
    Process.sleep(500)
    # Test with a known valid mode (e.g., Esc)
    mode_esc = ExTermbox.Const.InputMode.ESC
    assert ExTermbox.set_input_mode(mode_esc) == :ok

    # Test with another mode (e.g., Alt)
    mode_alt = ExTermbox.Const.InputMode.ALT
    assert ExTermbox.set_input_mode(mode_alt) == :ok

    # Test combining modes (if applicable, check termbox docs)
    # Assuming modes are bit flags
    mode_combined = Bitwise.bor(mode_esc, mode_alt)
    assert ExTermbox.set_input_mode(mode_combined) == :ok

    # Test setting back to current (should be ok)
    # mode_current = tb_select_input_mode(0) # C function, not directly callable here
    # Need a way to get current mode if we want to restore, or just test known values.
    assert ExTermbox.set_input_mode(ExTermbox.Const.InputMode.CURRENT) == :ok

    # Note: Cannot easily verify the *effect* of the mode change here.
  end

  test "sets output mode" do
    Process.sleep(500)

    # Test with known valid modes
    assert ExTermbox.set_output_mode(ExTermbox.Const.OutputMode.NORMAL) == :ok
    assert ExTermbox.set_output_mode(ExTermbox.Const.OutputMode.TRUECOLOR) == :ok
    # Maybe test 256 mode
    assert ExTermbox.set_output_mode(ExTermbox.Const.OutputMode.C256) == :ok
    # Back to current
    assert ExTermbox.set_output_mode(ExTermbox.Const.OutputMode.CURRENT) == :ok

    # Need to present for some modes to take effect, but verification is hard.
    assert ExTermbox.present() == :ok
  end

  test "sets clear attributes" do
    Process.sleep(500)

    fg = ExTermbox.Const.Color.YELLOW
    bg = ExTermbox.Const.Color.MAGENTA

    assert ExTermbox.set_clear_attributes(fg, bg) == :ok

    # Optionally call clear and present, although we can't verify the result easily
    assert ExTermbox.clear() == :ok
    assert ExTermbox.present() == :ok

    # Set back to default
    assert ExTermbox.set_clear_attributes(ExTermbox.Const.Color.DEFAULT, ExTermbox.Const.Color.DEFAULT) == :ok
    assert ExTermbox.clear() == :ok
    assert ExTermbox.present() == :ok
  end

  # --- BEGIN ADD Event Test ---
  test "receives synthetic event via debug command" do
    Process.sleep(500) # Ensure init is complete

    # Define the event we want to simulate (e.g., a key press)
    test_event = %{
      type: ExTermbox.Const.EventType.KEY, # tb_event type for key press
      mod: 0, # No modifier key
      key: ExTermbox.Const.Key.ARROW_UP, # Key code for Up Arrow
      ch: 0, # Character code (0 for non-char keys)
      w: 0, # Resize width (not used for key event)
      h: 0, # Resize height (not used for key event)
      x: 0, # Mouse x (not used for key event)
      y: 0 # Mouse y (not used for key event)
    }

    # Send the debug command to trigger the event emission from C
    assert ExTermbox.debug_send_event(test_event) == :ok

    # Assert that the PortHandler sends the {:termbox_event, event_map} message
    # to its owner (the test process in this case)
    assert_receive {:termbox_event, received_event_map}, 1000 # Timeout after 1 second

    # Verify the content of the received event map
    # Note: Protocol currently returns string keys from JSON
    assert received_event_map["type"] == ExTermbox.Const.EventType.KEY
    assert received_event_map["mod"] == 0
    assert received_event_map["key"] == ExTermbox.Const.Key.ARROW_UP
    assert received_event_map["ch"] == 0
    assert received_event_map["w"] == 0
    assert received_event_map["h"] == 0
    assert received_event_map["x"] == 0
    assert received_event_map["y"] == 0

  end
  # --- END ADD Event Test ---

  # TODO: Add more tests, e.g., for specific cell changes (if possible), events
end 