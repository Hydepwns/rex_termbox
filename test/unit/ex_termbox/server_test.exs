defmodule ExTermbox.ServerTest do
  use ExUnit.Case, async: true # Unit tests can often run async

  # Import Mox for defining mocks and expectations
  import Mox

  # Alias commonly used modules
  alias ExTermbox.Server
  alias ExTermbox.Event
  alias ExTermbox.Constants

  # Define the mock for the NIF module
  # We use :termbox2 because that's what Server calls directly.
  Mox.defmock(Termbox2Mock, for: :termbox2)

  # Polling interval used in Server (ensure consistency or make configurable)
  @poll_interval_ms 10

  setup :verify_on_exit! # Ensure Mox expectations are met

  describe "event polling and handling" do
    test "correctly handles and dispatches a key event" do
      # --- Arrange ---
      owner_pid = self()

      # Define the raw event tuple representing Ctrl+B (TB_EVENT_KEY, mod=0, key=TB_KEY_CTRL_B)
      key_ctrl_b = Constants.key(:ctrl_b)
      type_key = Constants.event_type(:key)
      # NIF Format assumption: {type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}
      raw_event_tuple = {type_key, 0, key_ctrl_b, 0, 0, 0, 0, 0}

      # Mock the initial tb_init() call during Server startup to return success
      expect(Termbox2Mock, :tb_init, fn -> Constants.error_code(:ok) end)

      # Start the Server process, linking it to the test process
      {:ok, server_pid} = Server.start_link(owner: owner_pid, name: nil) # Use dynamic name

      # Mock the tb_peek_event call:
      # - First call returns the raw event tuple
      # - Subsequent call returns no_event to prevent infinite loop in test
      expect(Termbox2Mock, :tb_peek_event, 2, fn _timeout_ms ->
        # This function will be called twice due to the expect arity 2
        # We return the event first, then no_event
        send(self(), :peek_called) # Send message to self to track calls
        receive do
          :return_event -> raw_event_tuple
        after
          0 -> Constants.error_code(:no_event) # Default to no_event if message not received
        end
      end)

      # Mock the tb_shutdown() call during termination
      expect(Termbox2Mock, :tb_shutdown, fn -> :ok end)

      # --- Act ---
      # The server should have started polling automatically.
      # Send the message to make the mock return the event on the *first* peek call
      send(self(), :return_event)

      # Wait briefly for the server to poll, process the event, and send the message.
      # Also wait for the second peek call to occur.
      assert_receive :peek_called, 50 # Wait for first peek
      assert_receive :peek_called, 50 # Wait for second peek

      # Assert that the owner (test process) received the correctly mapped event message
      assert_receive {:termbox_event, %Event{
                                        type: :key,
                                        mod: :unknown, # Modifier was 0, maps to :unknown
                                        key: :ctrl_b,
                                        ch: nil, # ch should be nil when key is present
                                        w: 0, h: 0, x: 0, y: 0
                                      }}, 100 # Timeout for receiving the message

      # --- Cleanup ---
      # Explicitly stop the server to trigger shutdown mock verification
      Server.stop(server_pid)
    end

    test "correctly handles and dispatches a resize event" do
      # --- Arrange ---
      owner_pid = self()
      new_width = 80
      new_height = 24

      # Define the raw event tuple representing a resize event
      type_resize = Constants.event_type(:resize)
      # NIF Format assumption: {type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}
      # For resize, only type, w, and h are relevant.
      raw_event_tuple = {type_resize, 0, 0, 0, new_width, new_height, 0, 0}

      # Mock init
      expect(Termbox2Mock, :tb_init, fn -> Constants.error_code(:ok) end)

      # Start Server
      {:ok, server_pid} = Server.start_link(owner: owner_pid, name: nil)

      # Mock peek_event (resize then no_event)
      expect(Termbox2Mock, :tb_peek_event, 2, fn _timeout_ms ->
        send(self(), :peek_called)
        receive do
          :return_event -> raw_event_tuple
        after
          0 -> Constants.error_code(:no_event)
        end
      end)

      # Mock shutdown
      expect(Termbox2Mock, :tb_shutdown, fn -> :ok end)

      # --- Act ---
      send(self(), :return_event) # Trigger mock to return resize event

      # Wait for polling
      assert_receive :peek_called, 50
      assert_receive :peek_called, 50

      # --- Assert ---
      # Check for correctly mapped resize event message
      assert_receive {:termbox_event, %Event{
                                        type: :resize,
                                        mod: :unknown, # Not relevant for resize
                                        key: nil,      # Not relevant for resize
                                        ch: nil,       # Not relevant for resize
                                        w: ^new_width,
                                        h: ^new_height,
                                        x: 0, # Not relevant for resize
                                        y: 0  # Not relevant for resize
                                      }}, 100

      # --- Cleanup ---
      Server.stop(server_pid)
    end

    test "correctly handles and dispatches a mouse event" do
      # --- Arrange ---
      owner_pid = self()
      mouse_x = 15
      mouse_y = 10

      # Define the raw event tuple representing a left mouse click
      type_mouse = Constants.event_type(:mouse)
      key_mouse_left = Constants.key(:mouse_left) # Key indicates the button/action
      # NIF Format assumption: {type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}
      # For mouse, type, key, x, and y are relevant.
      raw_event_tuple = {type_mouse, 0, key_mouse_left, 0, 0, 0, mouse_x, mouse_y}

      # Mock init
      expect(Termbox2Mock, :tb_init, fn -> Constants.error_code(:ok) end)

      # Start Server
      {:ok, server_pid} = Server.start_link(owner: owner_pid, name: nil)

      # Mock peek_event (mouse then no_event)
      expect(Termbox2Mock, :tb_peek_event, 2, fn _timeout_ms ->
        send(self(), :peek_called)
        receive do
          :return_event -> raw_event_tuple
        after
          0 -> Constants.error_code(:no_event)
        end
      end)

      # Mock shutdown
      expect(Termbox2Mock, :tb_shutdown, fn -> :ok end)

      # --- Act ---
      send(self(), :return_event) # Trigger mock to return mouse event

      # Wait for polling
      assert_receive :peek_called, 50
      assert_receive :peek_called, 50

      # --- Assert ---
      # Check for correctly mapped mouse event message
      assert_receive {:termbox_event, %Event{
                                        type: :mouse,
                                        mod: :unknown,      # Modifiers might be relevant for mouse? Check termbox.h (assuming 0 for now)
                                        key: :mouse_left,   # Key indicates mouse action
                                        ch: nil,
                                        w: 0, # Not relevant for this mouse event type
                                        h: 0, # Not relevant for this mouse event type
                                        x: ^mouse_x,
                                        y: ^mouse_y
                                      }}, 100

      # --- Cleanup ---
      Server.stop(server_pid)
    end

    test "correctly handles and dispatches a key event with modifier (Alt+a)" do
      # --- Arrange ---
      owner_pid = self()

      # Define the raw event tuple representing Alt+a
      # Type=Key, Mod=Alt, Key=0, Char='a'
      type_key = Constants.event_type(:key)
      mod_alt = Constants.modifier(:alt)
      char_a = ?a
      # NIF Format assumption: {type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}
      raw_event_tuple = {type_key, mod_alt, 0, char_a, 0, 0, 0, 0}

      # Mock init
      expect(Termbox2Mock, :tb_init, fn -> Constants.error_code(:ok) end)

      # Start Server
      {:ok, server_pid} = Server.start_link(owner: owner_pid, name: nil)

      # Mock peek_event (Alt+a then no_event)
      expect(Termbox2Mock, :tb_peek_event, 2, fn _timeout_ms ->
        send(self(), :peek_called)
        receive do
          :return_event -> raw_event_tuple
        after
          0 -> Constants.error_code(:no_event)
        end
      end)

      # Mock shutdown
      expect(Termbox2Mock, :tb_shutdown, fn -> :ok end)

      # --- Act ---
      send(self(), :return_event) # Trigger mock to return Alt+a event

      # Wait for polling
      assert_receive :peek_called, 50
      assert_receive :peek_called, 50

      # --- Assert ---
      # Check for correctly mapped Alt+a event message
      assert_receive {:termbox_event, %Event{
                                        type: :key,
                                        mod: :alt,
                                        key: nil, # Key is nil because raw key was 0
                                        ch: ^char_a,
                                        w: 0, h: 0, x: 0, y: 0
                                      }}, 100

      # --- Cleanup ---
      Server.stop(server_pid)
    end

    test "correctly handles and dispatches a simple character event ('b')" do
      # --- Arrange ---
      owner_pid = self()

      # Define the raw event tuple representing 'b'
      # Type=Key, Mod=0, Key=0, Char='b'
      type_key = Constants.event_type(:key)
      char_b = ?b
      # NIF Format assumption: {type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}
      raw_event_tuple = {type_key, 0, 0, char_b, 0, 0, 0, 0}

      # Mock init
      expect(Termbox2Mock, :tb_init, fn -> Constants.error_code(:ok) end)

      # Start Server
      {:ok, server_pid} = Server.start_link(owner: owner_pid, name: nil)

      # Mock peek_event ('b' then no_event)
      expect(Termbox2Mock, :tb_peek_event, 2, fn _timeout_ms ->
        send(self(), :peek_called)
        receive do
          :return_event -> raw_event_tuple
        after
          0 -> Constants.error_code(:no_event)
        end
      end)

      # Mock shutdown
      expect(Termbox2Mock, :tb_shutdown, fn -> :ok end)

      # --- Act ---
      send(self(), :return_event) # Trigger mock to return 'b' event

      # Wait for polling
      assert_receive :peek_called, 50
      assert_receive :peek_called, 50

      # --- Assert ---
      # Check for correctly mapped 'b' event message
      assert_receive {:termbox_event, %Event{
                                        type: :key,
                                        mod: :unknown, # Modifier was 0
                                        key: nil,      # Key is nil because raw key was 0
                                        ch: ^char_b,
                                        w: 0, h: 0, x: 0, y: 0
                                      }}, 100

      # --- Cleanup ---
      Server.stop(server_pid)
    end

    test "handles polling error without crashing or sending event" do
      # --- Arrange ---
      owner_pid = self()

      # Define the error code to simulate
      poll_error_code = Constants.error_code(:poll) # e.g., -14

      # Mock init
      expect(Termbox2Mock, :tb_init, fn -> Constants.error_code(:ok) end)

      # Start Server
      {:ok, server_pid} = Server.start_link(owner: owner_pid, name: nil)

      # Mock peek_event (error then no_event)
      expect(Termbox2Mock, :tb_peek_event, 2, fn _timeout_ms ->
        send(self(), :peek_called)
        receive do
          :return_error -> poll_error_code
        after
          0 -> Constants.error_code(:no_event)
        end
      end)

      # Mock shutdown
      expect(Termbox2Mock, :tb_shutdown, fn -> :ok end)

      # --- Act ---
      send(self(), :return_error) # Trigger mock to return error code

      # Wait for polling
      assert_receive :peek_called, 50
      assert_receive :peek_called, 50

      # --- Assert ---
      # Check that NO event message was sent to the owner
      ref = make_ref()
      send(owner_pid, {:check_mailbox, ref})
      # If an :termbox_event was sent, it would arrive before :check_mailbox
      receive do
        {:termbox_event, _event} -> flunk("Received unexpected :termbox_event after polling error")
        {:check_mailbox, ^ref} -> :ok # Expected: no event received
      after 100 ->
          flunk("Did not receive check_mailbox message")
      end

      # --- Cleanup ---
      Server.stop(server_pid)
    end

    # TODO: Add tests for other event types (resize, mouse)
    # TODO: Add tests for error handling during polling
    # TODO: Add tests for event mapping edge cases (unknown keys/types if possible)
  end
end