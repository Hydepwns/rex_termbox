defmodule ExTermbox.Protocol do
  @moduledoc """
  Defines the protocol for communication between Elixir and the C Termbox helper.
  Includes parsing/formatting functions.
  """
  require Logger

  # --- BEGIN ADD Regexes ---
  @ok_regex ~r/^OK$/
  @error_regex ~r/^ERROR\s+(\S+)$/
  @ok_cell_regex ~r/^OK_CELL\s+(-?\d+)\s+(-?\d+)\s+(.+)\s+(\d+)\s+(\d+)$/
  @ok_width_regex ~r/^OK_WIDTH\s+(\d+)$/
  @ok_height_regex ~r/^OK_HEIGHT\s+(\d+)$/
  @event_regex ~r/^EVENT\s+(\{.*\})$/
  # --- END ADD Regexes ---

  # --- BEGIN ADD Command Formatting ---
  # Formats the command string to be sent over the socket.
  # Note: C side expects a newline terminator, which send_socket_command should handle.

  @spec format_present_command :: String.t()
  def format_present_command, do: "PRESENT\n"

  @spec format_clear_command :: String.t()
  def format_clear_command, do: "CLEAR\n"

  def format_print_command(x, y, fg, bg, text) do
    # Ensure text doesn't contain newlines which would break the protocol
    safe_text = String.replace(text, "\n", " ")
    "print #{x} #{y} #{fg} #{bg} #{safe_text}\n"
  end

  def format_get_cell_command(x, y) do
    "get_cell #{x} #{y}\n"
  end

  @spec format_width_command :: String.t()
  def format_width_command, do: "WIDTH\n"

  @spec format_height_command :: String.t()
  def format_height_command, do: "HEIGHT\n"

  def format_change_cell_command(x, y, codepoint, fg, bg) do
    "change_cell #{x} #{y} #{codepoint} #{fg} #{bg}\n"
  end

  def format_set_cursor_command(x, y) do
    "set_cursor #{x} #{y}\n"
  end

  def format_set_input_mode_command(mode) when is_integer(mode) do
    "set_input_mode #{mode}\n"
  end

  def format_set_output_mode_command(mode) when is_integer(mode) do
    "set_output_mode #{mode}\n"
  end

  def format_set_clear_attributes_command(fg, bg)
      when is_integer(fg) and is_integer(bg) do
    "set_clear_attributes #{fg} #{bg}\n"
  end

  # --- END ADD Command Formatting ---

  # Parses the event string "type mod key ch w h x y" into a map
  def parse_event(data) do
    parts = String.split(data)

    with [type_s, mod_s, key_s, ch_s, w_s, h_s, x_s, y_s] <- parts,
         {:ok, type} <- parse_int(type_s, :type),
         {:ok, mod} <- parse_int(mod_s, :mod),
         {:ok, key} <- parse_int(key_s, :key),
         {:ok, ch} <- parse_uint(ch_s, :ch),
         {:ok, w} <- parse_int(w_s, :w),
         {:ok, h} <- parse_int(h_s, :h),
         {:ok, x} <- parse_int(x_s, :x),
         {:ok, y} <- parse_int(y_s, :y) do
      event_map = %{
        "type" => map_event_type(type),
        "mod" => map_event_mod(mod),
        "key" => map_event_key(key),
        "ch" => ch,
        "w" => w,
        "h" => h,
        "x" => x,
        "y" => y
      }

      {:ok, event_map}
    else
      _error -> {:error, :invalid_event_format}
    end
  end

  # Parses a complete line received from the C process via the socket
  # Returns a tuple indicating the line type and parsed data.
  def parse_socket_line(line) do
    cond do
      Regex.match?(@ok_regex, line) ->
        {:ok_response}

      Regex.run(@ok_width_regex, line, capture: :all_but_first) ->
        # \\ [width_s] is safe due to regex \d+
        [width_s] = Regex.run(@ok_width_regex, line, capture: :all_but_first)
        {:ok_width_response, String.to_integer(width_s)}

      Regex.run(@ok_height_regex, line, capture: :all_but_first) ->
        [height_s] = Regex.run(@ok_height_regex, line, capture: :all_but_first)
        {:ok_height_response, String.to_integer(height_s)}

      Regex.run(@ok_cell_regex, line, capture: :all_but_first) ->
        [x_s, y_s, char_utf8, fg_s, bg_s] = Regex.run(@ok_cell_regex, line, capture: :all_but_first)
        cell_data = %{
          x: String.to_integer(x_s),
          y: String.to_integer(y_s),
          # char: char_utf8, # Keep as UTF-8 string
          char: char_utf8,
          fg: String.to_integer(fg_s),
          bg: String.to_integer(bg_s)
        }
        {:ok_cell_response, cell_data}

      Regex.run(@event_regex, line, capture: :all_but_first) ->
        [json_str] = Regex.run(@event_regex, line, capture: :all_but_first)
        parse_event_json(json_str)

      Regex.run(@error_regex, line, capture: :all_but_first) ->
        [reason_s] = Regex.run(@error_regex, line, capture: :all_but_first)
        {:error_response, String.to_atom(reason_s)}

      true ->
        Logger.warning("[Protocol] Unparseable line received: '#{line}'")
        {:unparseable, line}
    end
  end

  # --- BEGIN ADD Private Helper Functions for Parsing ---
  defp _parse_ok do
    # Logger.debug("Protocol matched 'OK'")
    {:ok_response}
  end

  defp _parse_error(reason_s) do
    reason = String.trim(reason_s)
    Logger.error("Protocol received C Socket Error: #{reason}")
    {:error_response, reason}
  end

  defp _parse_ok_cell(x_s, y_s, char_s, fg_s, bg_s) do
    with {:ok, x} <- parse_int(x_s, :x),
         {:ok, y} <- parse_int(y_s, :y),
         # Char is already UTF8 string, no need to handle codepoint
         {:ok, fg} <- parse_int(fg_s, :fg),
         {:ok, bg} <- parse_int(bg_s, :bg) do
      # Logger.debug(
      #   "Protocol matched 'OK_CELL': x=#{x}, y=#{y}, char='#{char_s}', fg=#{fg}, bg=#{bg}"
      # )
      {:ok_cell_response, %{x: x, y: y, char: char_s, fg: fg, bg: bg}}
    else
      error ->
        Logger.error(
          "Protocol failed to parse OK_CELL data '#{x_s} #{y_s} #{char_s} #{fg_s} #{bg_s}': #{inspect(error)}"
        )

        {:parse_error, :ok_cell, {x_s, y_s, char_s, fg_s, bg_s}, error}
    end
  end

  # Handle case where regex matches but capture group extraction failed (shouldn't happen with drop(1))
  # Or if the regex itself was constructed incorrectly for the number of captures.
  defp _parse_ok_cell(other_captures) do
    Logger.error(
      "Protocol received OK_CELL line with unexpected capture format: #{inspect(other_captures)}"
    )

    {:parse_error, :ok_cell_internal_format, inspect(other_captures)}
  end

  defp _parse_ok_width(width_s) do
    case parse_int(width_s, :width) do
      {:ok, width} ->
        # Logger.debug("Protocol matched 'OK_WIDTH': #{width}")
        {:ok_width_response, width}

      error ->
        Logger.error(
          "Protocol failed to parse OK_WIDTH data '#{width_s}': #{inspect(error)}"
        )

        {:parse_error, :ok_width, width_s, error}
    end
  end

  defp _parse_ok_height(height_s) do
    case parse_int(height_s, :height) do
      {:ok, height} ->
        # Logger.debug("Protocol matched 'OK_HEIGHT': #{height}")
        {:ok_height_response, height}

      error ->
        Logger.error(
          "Protocol failed to parse OK_HEIGHT data '#{height_s}': #{inspect(error)}"
        )

        {:parse_error, :ok_height, height_s, error}
    end
  end

  defp _parse_event_line(event_json, _original_line) do
    # Logger.debug("Protocol matched 'EVENT JSON': #{event_json}")
    # Use Jason (or similar) to decode the JSON string
    case Jason.decode(event_json) do
      {:ok, event_data_map_str_keys} ->
        # Convert integer values from C to Elixir atoms where appropriate
        # Assume keys are strings: "type", "mod", "key", "ch", "w", "h", "x", "y"
        try do
          event_map_atom_keys = %{
            type: map_event_type(event_data_map_str_keys["type"]),
            mod: map_event_mod(event_data_map_str_keys["mod"]),
            key: map_event_key(event_data_map_str_keys["key"]),
            ch: event_data_map_str_keys["ch"],
            w: event_data_map_str_keys["w"],
            h: event_data_map_str_keys["h"],
            x: event_data_map_str_keys["x"],
            y: event_data_map_str_keys["y"]
          }
          # Logger.debug("Protocol decoded event JSON: #{inspect(event_map_atom_keys)}")
          {:event, event_map_atom_keys}
        rescue e in KeyError -> 
          Logger.error(
            "Protocol failed to map event fields from JSON '#{event_json}': Missing key #{inspect(e.key)}"
          )
          {:parse_error, :event_map, event_json, :missing_key}
        end

      {:error, reason} ->
        Logger.error(
          "Protocol failed to decode event JSON '#{event_json}': #{inspect(reason)}"
        )
        {:parse_error, :event_json, event_json, reason}
    end
  end

  defp _parse_unknown(trimmed_line) do
    Logger.warning(
      "Protocol received unknown line format from socket: '#{trimmed_line}'"
    )

    {:unknown_line, trimmed_line}
  end

  # Helper to parse the JSON-like event string
  defp parse_event_json(json_str) do
    try do
      # Jason is likely overkill, use basic string parsing or regex if format is stable
      # Example using manual parsing (adjust based on exact C format):
      # EVENT {"type":1, "mod":0, "key":65, "ch":97, "w":0, "h":0, "x":0, "y":0}
      data = parse_simple_json_like(json_str)

      # Convert keys to atoms and values to correct types
      event_map = Enum.into(data, %{}, fn {k, v} -> {String.to_atom(k), v} end)

      # Convert integer type back to atom for consistency?
      # Maybe not, keep integers as C sends them.
      # type_atom = Constants.event_type_atom(Map.get(event_map, :type))
      # event_map = Map.put(event_map, :type, type_atom)

      # Convert atoms back to constants if needed (e.g., for event type)
      # Assuming C side sends integers for type, mod, key, ch
      # If C sends names, we need a lookup here.
      {:event, event_map}
    rescue
      e ->
        Logger.error("[Protocol] Failed to parse event JSON '#{json_str}': #{inspect(e)}")
        {:error, :invalid_event_format}
        # {:unparseable, json_str} # Return specific error
    end
  end

  # Extremely basic parser for the specific {"key":value, ...} format
  # WARNING: Very fragile, assumes simple integer values and double-quoted keys
  defp parse_simple_json_like(str) do
    str
    |> String.trim("{}") # Trim braces first
    |> String.split(",", trim: true)
    |> Enum.map(fn pair ->
      # Use String.split/3 with parts: 2 for safety
      case String.split(pair, ":", parts: 2, trim: true) do
        [key, value] ->
          key_trimmed = String.trim(key, "\"")
          # Attempt integer conversion, handle potential errors
          case Integer.parse(String.trim(value)) do
            {int_val, ""} -> {key_trimmed, int_val}
            _ ->
              Logger.error("Failed to parse integer for field #{key_trimmed} from '#{value}'") # Log error
              {key_trimmed, String.trim(value)} # Keep original value on parse error
          end
        _ ->
          # Handle cases where splitting by ':' fails unexpectedly
          Logger.warning("[Protocol] Malformed key-value pair in event: '#{pair}'")
          {nil, nil} # Or some other error indicator
      end
    end)
    |> Enum.reject(&match?({nil, nil}, &1)) # Remove malformed pairs
    |> Map.new()
  end

  # --- END ADD Private Helper Functions for Parsing ---

  defp parse_int(s, field) do
    case Integer.parse(s) do
      {int, ""} ->
        {:ok, int}

      _ ->
        Logger.error("Failed to parse integer for field :#{field} from '#{s}'")
        {:error, {:invalid_integer, field, s}}
    end
  end

  defp parse_uint(s, field) do
    case Integer.parse(s) do
      {int, ""} when int >= 0 ->
        {:ok, int}

      _ ->
        Logger.error(
          "Failed to parse unsigned integer for field :#{field} from '#{s}'"
        )

        {:error, {:invalid_uint, field, s}}
    end
  end

  # --- Mappings (based on termbox.h) --- #

  # TB_EVENT_*
  defp map_event_type(1), do: :key
  defp map_event_type(2), do: :resize
  defp map_event_type(3), do: :mouse
  # Or raise error?
  defp map_event_type(_other), do: :unknown

  # TB_MOD_*
  defp map_event_mod(0), do: :none # Explicitly map 0 to :none
  defp map_event_mod(1), do: :alt
  # Assuming TB_MOD_MOTION is 2
  defp map_event_mod(2), do: :motion
  # No modifier or unknown
  defp map_event_mod(_other), do: nil # Keep nil for other unknown/invalid

  # TB_KEY_*
  defp map_event_key(0xFFFF), do: :f1
  defp map_event_key(0xFFFE), do: :f2
  defp map_event_key(0xFFFD), do: :f3
  defp map_event_key(0xFFFC), do: :f4
  defp map_event_key(0xFFFB), do: :f5
  defp map_event_key(0xFFFA), do: :f6
  defp map_event_key(0xFFF9), do: :f7
  defp map_event_key(0xFFF8), do: :f8
  defp map_event_key(0xFFF7), do: :f9
  defp map_event_key(0xFFF6), do: :f10
  defp map_event_key(0xFFF5), do: :f11
  defp map_event_key(0xFFF4), do: :f12
  defp map_event_key(0xFFF3), do: :insert
  defp map_event_key(0xFFF2), do: :delete
  defp map_event_key(0xFFF1), do: :home
  defp map_event_key(0xFFF0), do: :end
  defp map_event_key(0xFFEF), do: :pgup
  defp map_event_key(0xFFEE), do: :pgdn
  defp map_event_key(0xFFED), do: :arrow_up
  defp map_event_key(0xFFEC), do: :arrow_down
  defp map_event_key(0xFFEB), do: :arrow_left
  defp map_event_key(0xFFEA), do: :arrow_right
  # MOUSE LEFT
  defp map_event_key(0xFFE9), do: :mouse_left
  # MOUSE RIGHT
  defp map_event_key(0xFFE8), do: :mouse_right
  # MOUSE MIDDLE
  defp map_event_key(0xFFE7), do: :mouse_middle
  # MOUSE RELEASE
  defp map_event_key(0xFFE6), do: :mouse_release
  # MOUSE WHEEL UP
  defp map_event_key(0xFFE5), do: :mouse_wheel_up
  # MOUSE WHEEL DOWN
  defp map_event_key(0xFFE4), do: :mouse_wheel_down
  # ASCII Control Codes
  # Usually Ctrl+` or Ctrl+Space?
  defp map_event_key(0x00), do: :ctrl_tilde
  # defp map_event_key(0x00), do: :ctrl_2 # Alias often Ctrl+@
  defp map_event_key(0x01), do: :ctrl_a
  defp map_event_key(0x02), do: :ctrl_b
  defp map_event_key(0x03), do: :ctrl_c
  defp map_event_key(0x04), do: :ctrl_d
  defp map_event_key(0x05), do: :ctrl_e
  defp map_event_key(0x06), do: :ctrl_f
  defp map_event_key(0x07), do: :ctrl_g
  # Or :ctrl_h
  defp map_event_key(0x08), do: :backspace
  # Or :ctrl_i
  defp map_event_key(0x09), do: :tab
  # Usually Line Feed
  defp map_event_key(0x0A), do: :ctrl_j
  defp map_event_key(0x0B), do: :ctrl_k
  defp map_event_key(0x0C), do: :ctrl_l
  # Or :ctrl_m
  defp map_event_key(0x0D), do: :enter
  defp map_event_key(0x0E), do: :ctrl_n
  defp map_event_key(0x0F), do: :ctrl_o
  defp map_event_key(0x10), do: :ctrl_p
  defp map_event_key(0x11), do: :ctrl_q
  defp map_event_key(0x12), do: :ctrl_r
  defp map_event_key(0x13), do: :ctrl_s
  defp map_event_key(0x14), do: :ctrl_t
  defp map_event_key(0x15), do: :ctrl_u
  defp map_event_key(0x16), do: :ctrl_v
  defp map_event_key(0x17), do: :ctrl_w
  defp map_event_key(0x18), do: :ctrl_x
  defp map_event_key(0x19), do: :ctrl_y
  defp map_event_key(0x1A), do: :ctrl_z
  # Or :ctrl_lsquare_bracket or :ctrl_3
  defp map_event_key(0x1B), do: :esc
  # Usually Ctrl+\
  defp map_event_key(0x1C), do: :ctrl_4
  # Usually Ctrl+]
  defp map_event_key(0x1D), do: :ctrl_5
  # Usually Ctrl+^
  defp map_event_key(0x1E), do: :ctrl_6
  # Usually Ctrl+_ or Ctrl+-
  defp map_event_key(0x1F), do: :ctrl_7
  defp map_event_key(0x20), do: :space
  # Or :ctrl_8
  defp map_event_key(0x7F), do: :backspace2

  # Convert the integer key from JSON back to an atom *before* mapping
  # Or handle the atom mapping directly in the key mapping function if preferred
  # For simplicity, let's assume key is passed as integer from C
  defp map_event_key(other_key), do: {:unknown_key, other_key}

  # --- BEGIN ADD DEBUG_SEND_EVENT Format ---
  # Format: DEBUG_SEND_EVENT type mod key ch w h x y
  def format_debug_send_event_command(type_a, mod_i, key_i, ch_i, w_i, h_i, x_i, y_i)
      when is_atom(type_a) and is_integer(mod_i) and is_integer(key_i) and is_integer(ch_i) and
             is_integer(w_i) and is_integer(h_i) and is_integer(x_i) and is_integer(y_i) do
    type_i = ExTermbox.Constants.event_type(type_a)
    # mod_i = ExTermbox.Constants.mod(mod_a) # Mod is already an integer, no lookup needed

    # Ensure basic validity, though C side might do more checks
    valid_type? = type_i in Map.values(ExTermbox.Constants.event_types())
    # Mod validity is less critical to check here, C side handles it
    # valid_mod? = mod_i in Map.values(Constants.mod_map())

    if valid_type? do
      # Pass integers directly
      command_str = "DEBUG_SEND_EVENT #{type_i} #{mod_i} #{key_i} #{ch_i} #{w_i} #{h_i} #{x_i} #{y_i}"
      {:ok, command_str <> "\n"}
    else
      {:error, :invalid_event_type}
    end
  end

  # --- END ADD DEBUG_SEND_EVENT Format ---
end
