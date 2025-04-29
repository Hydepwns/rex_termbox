defmodule ExTermbox.Buffer do
  require Logger

  @doc """
  Processes an incoming data chunk, appending it to the buffer and extracting lines.

  Returns `{:lines, lines, remaining_buffer}` or `{:incomplete, buffer}` where 
  `lines` is a list of complete, trimmed lines found in the combined buffer, 
  and `remaining_buffer` / `buffer` is the content after the last newline or the
  entire buffer if no newline was found.
  """
  def process(buffer, data_chunk) do
    # Ensure data_chunk is a string for String.split
    data_string = if is_binary(data_chunk), do: IO.iodata_to_binary(data_chunk), else: data_chunk
    new_buffer = buffer <> data_string
    # Pass an empty list accumulator to process_lines
    process_lines(new_buffer, [])
  end

  # Recursively processes the buffer, accumulating lines
  # Returns {:lines, list_of_lines, remaining_buffer} or {:incomplete, buffer}
  defp process_lines(buffer, acc_lines) do
    case String.split(buffer, "\n", parts: 2) do
      # No newline found in the remaining buffer part
      [remaining_buffer_part] ->
        cond do
          acc_lines != [] ->
            {:lines, Enum.reverse(acc_lines), remaining_buffer_part}

          remaining_buffer_part != "" ->
            {:incomplete, remaining_buffer_part}

          true ->
            # Buffer is empty and no lines were accumulated
            {:lines, [], ""}
        end

      # Found a line and the rest of the buffer
      [line, rest] ->
        # Trim the extracted line ONLY
        trimmed_line = String.trim(line)
        # Recursively process the rest of the buffer, adding the trimmed line
        process_lines(rest, [trimmed_line | acc_lines])
    end # end case
  end # end process_lines
end # end defmodule
