defmodule ExTermbox.Protocol do
  @moduledoc """
  Defines the protocol for communication between Elixir and the C Termbox helper.
  Includes parsing/formatting functions.
  """
  require Logger

  # --- BEGIN ADD Regexes ---
  @ok_regex ~r/^OK$/i
  @error_regex ~r/^ERROR\\s+(.*)$/
  @ok_cell_regex ~r/^OK_CELL\\s+(\\S+)\\s+(\\S+)\\s+(.+?)\\s+(\\S+)\\s+(\\S+)$/
  @ok_width_regex ~r/^OK_WIDTH\\s+(\\S+)$/
  @ok_height_regex ~r/^OK_HEIGHT\\s+(\\S+)$/
  @event_regex ~r/^EVENT\\s+(.*)$/
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
    "print #{x} #{y} #{fg} #{bg} #{safe_text}"
  end

  def format_get_cell_command(x, y) do
    "get_cell #{x} #{y}"
  end

  @spec format_width_command :: String.t()
  def format_width_command, do: "WIDTH\n"

  @spec format_height_command :: String.t()
  def format_height_command, do: "HEIGHT\n"

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

  def format_set_clear_attributes_command(fg, bg)
      when is_integer(fg) and is_integer(bg) do
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

    # --- BEGIN REFACTOR parse_socket_line (Fix Guard Error) ---
    # Check for simple OK case first, as Regex.match? cannot be in guard
    if Regex.match?(@ok_regex, trimmed_line) do
      _parse_ok()
    else
      # Handle other cases using Regex.run (which is not in a guard here)
      cond do
        captures = Regex.run(@error_regex, trimmed_line) ->
          # ["ERROR ...", "reason"]
          _parse_error(captures |> Enum.at(1))

        captures = Regex.run(@ok_cell_regex, trimmed_line) ->
          # ["OK_CELL ...", x_s, y_s, char_utf8, fg_s, bg_s]
          _parse_ok_cell(captures |> Enum.drop(1))

        captures = Regex.run(@ok_width_regex, trimmed_line) ->
          # ["OK_WIDTH ...", width_s]
          _parse_ok_width(captures |> Enum.at(1))

        captures = Regex.run(@ok_height_regex, trimmed_line) ->
          # ["OK_HEIGHT ...", height_s]
          _parse_ok_height(captures |> Enum.at(1))

        captures = Regex.run(@event_regex, trimmed_line) ->
          # ["EVENT ...", event_data]
          # Pass original for logging
          _parse_event_line(captures |> Enum.at(1), trimmed_line)

        true ->
          # Fallback for unknown format
          _parse_unknown(trimmed_line)
      end
    end

    # --- END REFACTOR parse_socket_line (Fix Guard Error) ---
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

  defp _parse_ok_cell([x_s, y_s, char_utf8, fg_s, bg_s]) do
    with {:ok, x} <- parse_int(x_s, :x),
         {:ok, y} <- parse_int(y_s, :y),
         # Char is already UTF-8 string from C
         {:ok, fg} <- parse_uint(fg_s, :fg),
         {:ok, bg} <- parse_uint(bg_s, :bg) do
      # Logger.debug("Protocol matched 'OK_CELL': x=#{x}, y=#{y}, char='#{char_utf8}', fg=#{fg}, bg=#{bg}")
      cell_data = %{
        x: x,
        y: y,
        # Keep as string
        char: char_utf8,
        fg: fg,
        bg: bg
      }

      {:ok_cell_response, cell_data}
    else
      error ->
        original_data = "#{x_s} #{y_s} #{char_utf8} #{fg_s} #{bg_s}"

        Logger.error(
          "Protocol failed to parse OK_CELL data '#{original_data}': #{inspect(error)}"
        )

        {:parse_error, :ok_cell, original_data, error}
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

  defp _parse_event_line(event_data, _original_line) do
    # Logger.debug("Protocol matched 'EVENT data': #{event_data}")
    case parse_event(event_data) do
      {:ok, event_map} ->
        # Logger.debug("Protocol decoded event JSON: #{inspect(event_map)}")
        {:event, event_map}

      {:error, reason} ->
        Logger.error(
          "Protocol failed to parse event data '#{event_data}': #{inspect(reason)}"
        )

        {:parse_error, :event, event_data, reason}
    end
  end

  defp _parse_unknown(trimmed_line) do
    Logger.warning(
      "Protocol received unknown line format from socket: '#{trimmed_line}'"
    )

    {:unknown_line, trimmed_line}
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

  # --- BEGIN ADD DEBUG_SEND_EVENT Format ---
  def format_debug_send_event_command(type, mod, key, ch, w, h, x, y) do
    "DEBUG_SEND_EVENT #{type} #{mod} #{key} #{ch} #{w} #{h} #{x} #{y}"
  end

  # --- END ADD DEBUG_SEND_EVENT Format ---
end
