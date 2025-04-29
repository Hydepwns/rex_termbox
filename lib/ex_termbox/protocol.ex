defmodule ExTermbox.Protocol do
  require Logger

  # --- BEGIN ADD Command Formatting ---
  # Formats the command string to be sent over the socket.
  # Note: C side expects a newline terminator, which send_socket_command should handle.

  def format_present_command(), do: "present"
  def format_clear_command(), do: "clear"

  def format_print_command(x, y, fg, bg, text) do
    # Ensure text doesn't contain newlines which would break the protocol
    safe_text = String.replace(text, "\n", " ")
    "print #{x} #{y} #{fg} #{bg} #{safe_text}"
  end

  def format_get_cell_command(x, y) do
    "get_cell #{x} #{y}"
  end

  def format_width_command(), do: "width"
  def format_height_command(), do: "height"

  def format_change_cell_command(x, y, codepoint, fg, bg) do
    "change_cell #{x} #{y} #{codepoint} #{fg} #{bg}"
  end

  def format_set_cursor_command(x, y) do
    "set_cursor #{x} #{y}"
  end

  def format_set_input_mode_command(mode) when is_integer(mode) do
    "set_input_mode #{mode}"
  end

  def format_set_output_mode_command(mode) when is_integer(mode) do
    "set_output_mode #{mode}"
  end

  def format_set_clear_attributes_command(fg, bg) when is_integer(fg) and is_integer(bg) do
    "set_clear_attributes #{fg} #{bg}"
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
    trimmed_line = String.trim(line)
    # Logger.debug("Protocol parsing Socket Line: '#{trimmed_line}'")

    cond do
      # Match exact "OK"
      String.downcase(trimmed_line) == "ok" ->
        # Logger.debug("Protocol matched 'OK'")
        {:ok_response}

      # Match "ERROR <reason>"
      String.starts_with?(trimmed_line, "ERROR ") ->
        reason = String.slice(trimmed_line, 6..-1//-1) |> String.trim()
        Logger.error("Protocol received C Socket Error: #{reason}")
        {:error_response, reason}

      # --- BEGIN ADD OK_CELL Parsing ---
      # Match "OK_CELL <x> <y> <char_utf8> <fg_raw> <bg_raw>"
      String.starts_with?(trimmed_line, "OK_CELL ") ->
        data_part = String.slice(trimmed_line, 8..-1//-1) |> String.trim()
        # Split carefully, the char might be multi-byte or contain spaces if not handled well in C
        # Assuming C sends single space delimiters correctly.
        parts = String.split(data_part, " ", parts: 5) # Split into max 5 parts: x, y, char, fg, bg

        case parts do
          [x_s, y_s, char_utf8, fg_s, bg_s] ->
            with {:ok, x} <- parse_int(x_s, :x),
                 {:ok, y} <- parse_int(y_s, :y),
                 # Char is already UTF-8 string from C
                 {:ok, fg} <- parse_uint(fg_s, :fg),
                 {:ok, bg} <- parse_uint(bg_s, :bg) do

                # Logger.debug("Protocol matched 'OK_CELL': x=#{x}, y=#{y}, char='#{char_utf8}', fg=#{fg}, bg=#{bg}")
                 cell_data = %{
                   x: x,
                   y: y,
                   char: char_utf8, # Keep as string
                   fg: fg,
                   bg: bg
                 }
                {:ok_cell_response, cell_data}
            else
               error ->
                 Logger.error("Protocol failed to parse OK_CELL data '#{data_part}': #{inspect(error)}")
                 {:parse_error, :ok_cell, data_part, error}
            end
          _ ->
             Logger.error("Protocol received malformed OK_CELL line: '#{trimmed_line}'")
            {:parse_error, :ok_cell_format, trimmed_line}
        end
      # --- END ADD OK_CELL Parsing ---

      # Match "OK_WIDTH <value>"
      String.starts_with?(trimmed_line, "OK_WIDTH ") ->
        data_part = String.slice(trimmed_line, 9..-1//-1) |> String.trim()
        case parse_int(data_part, :width) do
          {:ok, width} ->
            # Logger.debug("Protocol matched 'OK_WIDTH': #{width}")
            {:ok_width_response, width}
          error ->
            Logger.error("Protocol failed to parse OK_WIDTH data '#{data_part}': #{inspect(error)}")
            {:parse_error, :ok_width, data_part, error}
        end

      # Match "OK_HEIGHT <value>"
      String.starts_with?(trimmed_line, "OK_HEIGHT ") ->
        data_part = String.slice(trimmed_line, 10..-1//-1) |> String.trim()
        case parse_int(data_part, :height) do
          {:ok, height} ->
            # Logger.debug("Protocol matched 'OK_HEIGHT': #{height}")
            {:ok_height_response, height}
          error ->
            Logger.error("Protocol failed to parse OK_HEIGHT data '#{data_part}': #{inspect(error)}")
            {:parse_error, :ok_height, data_part, error}
        end

      # Match "EVENT <data>"
      String.starts_with?(trimmed_line, "EVENT ") ->
        event_data = String.slice(trimmed_line, 6..-1//-1) |> String.trim()
        # Logger.debug("Protocol matched 'EVENT data': #{event_data}")

        case parse_event(event_data) do
          {:ok, event_map} ->
            # Further map raw values if needed (e.g., type, mod, key to atoms)
            # For now, keep the structure as decoded.
             # Logger.debug("Protocol decoded event JSON: #{inspect(event_map)}")
            {:event, event_map}

          {:error, reason} ->
            Logger.error(
              "Protocol failed to parse event data '#{event_data}': #{inspect(reason)}"
            )

            {:parse_error, :event, event_data, reason}
        end

      # Unknown line format
      true ->
        Logger.warning(
          "Protocol received unknown line format from socket: '#{trimmed_line}'"
        )

        {:unknown_line, trimmed_line}
    end
  end

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
  defp map_event_mod(1), do: :alt
  # Assuming TB_MOD_MOTION is 2
  defp map_event_mod(2), do: :motion
  # No modifier or unknown
  defp map_event_mod(_other), do: nil

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
  defp map_event_key(other_key), do: {:unknown_key, other_key}
end
