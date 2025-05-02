defmodule ExTermbox.Server do
  @moduledoc """
  GenServer managing the Termbox NIF lifecycle and event polling.
  """
  use GenServer

  require Logger

  # Import Constants for easier access
  alias ExTermbox.Constants
  alias ExTermbox.Event # Add alias for the Event struct

  # TODO: Make poll interval configurable
  @poll_interval_ms 10
  # Add a slightly longer interval for rescheduling after errors to avoid spamming
  @poll_error_interval_ms 50

  defstruct owner: nil

  # --- Client API ---

  def start_link(opts) do
    # Opts likely include the owner pid for sending events
    # Example: opts = [owner: self()]
    # Use registered name from ExTermbox module
    GenServer.start_link(__MODULE__, opts, name: ExTermbox.Server)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    owner_pid = Keyword.fetch!(opts, :owner)

    Logger.debug("Initializing Termbox via :termbox2.tb_init()...")

    # Call NIF directly via the termbox2 module
    init_result = :termbox2.tb_init()
    # Get the expected :ok code *before* the case
    ok_code = Constants.error_code(:ok)

    case init_result do
      # Use the pre-fetched ok_code
      ^ok_code ->
        Logger.debug("Termbox initialized successfully.")
        # Start the event polling loop
        send(self(), :poll_events)
        {:ok, %{owner: owner_pid}}

      # Handle potential error tuples (NIF might return this?)
      {:error, reason} ->
        Logger.error("Failed to initialize Termbox: #{inspect(reason)}")
        {:stop, {:termbox_init_failed, reason}}

      # Handle specific error codes
      error_code when is_integer(error_code) and error_code < 0 ->
        error_atom =
          Constants.error_codes()
          |> Enum.find(fn {_k, v} -> v == error_code end)
          |> elem(0)
          || :unknown_error_code

        Logger.error("Failed to initialize Termbox: #{error_atom} (#{error_code})")
        {:stop, {:termbox_init_failed, {error_atom, error_code}}}

      other ->
        Logger.error("Unexpected return from :termbox2.tb_init: #{inspect(other)}")
        {:stop, {:unexpected_init_return, other}}
    end
  end

  @impl true
  def handle_info(:poll_events, state) do
    # Timeout value passed to tb_peek_event.
    # We use a short timeout (0ms) because we rely on Process.send_after for polling interval.
    peek_timeout_ms = 0
    ok_code = Constants.error_code(:ok) # Typically 0

    # Determine the reschedule interval based on the poll result
    reschedule_interval = 
      case :termbox2.tb_peek_event(peek_timeout_ms) do
        # --- Normal Event --- #
        {:ok, {type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}} ->
          p_parse_and_send_event({type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}, state)
          @poll_interval_ms # Return normal interval

        # --- Timeout (No Event) --- #
        ^ok_code ->
           :ok # Side effect: none
           @poll_interval_ms # Return normal interval

        # --- Specific Unexpected Format from NIF --- #
        {-6, 0, 0, 0} ->
          Logger.warning("Termbox event polling received specific error tuple {-6, 0, 0, 0}. Possible TB_ERR_POLL?")
          @poll_error_interval_ms # Return error interval

        # --- General Error --- #
        error_code when is_integer(error_code) and error_code < 0 ->
          error_atom =
            Constants.error_codes()
            |> Enum.find_value(:unknown_error_code, fn {k, v} -> if v == error_code, do: k end)

          Logger.warning("Termbox event polling error: #{error_atom} (#{error_code})")
          @poll_error_interval_ms # Return error interval

        # --- Other Unexpected --- #
        other ->
          Logger.warning("Unexpected return format from :termbox2.tb_peek_event: #{inspect(other)}")
          @poll_error_interval_ms # Return error interval
      end

    # Schedule the next poll using the determined interval
    Process.send_after(self(), :poll_events, reschedule_interval)
    {:noreply, state}
  end

  # Catch-all for other info messages
  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unexpected message in #{__MODULE__}: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- GenServer API Implementations --- #

  @impl true
  def handle_call(:present, _from, state) do
    # Use Constants for result checking
    ok_code = Constants.error_code(:ok)
    case :termbox2.tb_present() do
      ^ok_code -> {:reply, :ok, state}
      error_code ->
        error_atom = map_integer_to_atom(error_code, Constants.error_codes())
        {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
     # Use Constants for result checking
    ok_code = Constants.error_code(:ok)
    case :termbox2.tb_clear() do
      ^ok_code -> {:reply, :ok, state}
      error_code ->
        error_atom = map_integer_to_atom(error_code, Constants.error_codes())
        {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call(:width, _from, state) do
    # NIF returns width directly or error code
    case :termbox2.tb_width() do
       width when is_integer(width) and width >= 0 -> {:reply, {:ok, width}, state}
       error_code ->
         error_atom = map_integer_to_atom(error_code, Constants.error_codes())
         {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call(:height, _from, state) do
    # NIF returns height directly or error code
    case :termbox2.tb_height() do
       height when is_integer(height) and height >= 0 -> {:reply, {:ok, height}, state}
       error_code ->
         error_atom = map_integer_to_atom(error_code, Constants.error_codes())
         {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call({:set_input_mode, mode_int}, _from, state) do
    case :termbox2.tb_set_input_mode(mode_int) do
       # NIF returns input mode on success, or error code
       mode when is_integer(mode) and mode >= 0 -> {:reply, :ok, state} # Assume :ok if return >= 0
       error_code ->
         error_atom = map_integer_to_atom(error_code, Constants.error_codes())
         {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call({:set_output_mode, mode_int}, _from, state) do
    case :termbox2.tb_set_output_mode(mode_int) do
      # NIF returns output mode on success, or error code
       mode when is_integer(mode) and mode >= 0 -> {:reply, :ok, state} # Assume :ok if return >= 0
       error_code ->
         error_atom = map_integer_to_atom(error_code, Constants.error_codes())
         {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call({:set_clear_attributes, fg_int, bg_int}, _from, state) do
    ok_code = Constants.error_code(:ok)
    case :termbox2.tb_set_clear_attrs(fg_int, bg_int) do
      ^ok_code -> {:reply, :ok, state}
      error_code ->
        error_atom = map_integer_to_atom(error_code, Constants.error_codes())
        {:reply, {:error, {error_atom, error_code}}, state}
    end
  end

  @impl true
  def handle_call({:get_cell, x, y}, _from, state) when is_integer(x) and is_integer(y) do
    # The tb_get_cell function is not currently implemented in the termbox2_nif library
    # Return an appropriate error instead of trying to call the missing function
    Logger.warning("get_cell(#{x}, #{y}) was called, but :termbox2_nif.tb_get_cell/2 is not implemented")
    {:reply, {:error, {:not_implemented, "tb_get_cell/2 is not available in the current termbox2_nif version"}}, state}
  end

  # Catch-all for unhandled calls
  @impl true
  def handle_call(msg, _from, state) do
    Logger.warning("Received unexpected call in #{__MODULE__}: #{inspect(msg)}")
    {:reply, :error_unhandled_call, state}
  end

  # Casts for quick operations
  @impl true
  def handle_cast({:set_cursor, x, y}, state) do
    # NIF returns error code or OK, but cast ignores it
    :termbox2.tb_set_cursor(x, y)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:change_cell, x, y, codepoint, fg, bg}, state) do
    # NIF returns error code or OK, but cast ignores it
    :termbox2.tb_set_cell(x, y, codepoint, fg, bg)
    {:noreply, state}
  end

  # Catch-all for unhandled casts
  @impl true
  def handle_cast(msg, state) do
    Logger.warning("Received unexpected cast in #{__MODULE__}: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug("Terminating Termbox Server. Reason: #{inspect(reason)}. Shutting down NIF.")
    :termbox2.tb_shutdown()
    :ok
  end

  # --- Private Helpers --- #

  # Helper to parse the raw NIF event tuple and send it to the owner
  defp p_parse_and_send_event({type_int, mod_int, key_int, ch_int, w_int, h_int, x_int, y_int}, state) do
    # Map integers to atoms using Constants
    event_type_atom = map_integer_to_atom(type_int, Constants.event_types())
    event_mod_atom = map_integer_to_atom(mod_int, Constants.modifiers())
    event_key_atom = map_integer_to_atom(key_int, Constants.keys())

    # Handle cases where mapping fails (shouldn't happen with valid NIF data)
    if event_type_atom == :unknown do
      Logger.warning("Received unknown event type integer from NIF: #{type_int}")
    else
      # Construct the event struct with mapped atoms
      # For key events, decide if `key` or `ch` is primary.
      # Termbox2 spec: `key` xor `ch` (one will be zero)
      event_struct = %Event{
        type: event_type_atom,
        mod: event_mod_atom,
        # Prefer the mapped key atom if key_int is non-zero, otherwise use ch_int
        key: if(key_int != 0, do: event_key_atom, else: nil),
        ch: if(key_int == 0 and ch_int != 0, do: ch_int, else: nil),
        # Other fields are direct integers
        w: w_int,
        h: h_int,
        x: x_int,
        y: y_int
      }
      # Send the mapped event to the owner
      send(state.owner, {:termbox_event, event_struct})
    end
  end

  # Helper to map integer constants to atoms using a provided map.
  # Returns the atom key if found, otherwise :unknown.
  defp map_integer_to_atom(int_val, const_map) when is_integer(int_val) and is_map(const_map) do
    Enum.find_value(const_map, :unknown, fn {key_atom, val} ->
      if val == int_val, do: key_atom
    end)
  end
  defp map_integer_to_atom(_, _), do: :unknown # Handle invalid input
end 