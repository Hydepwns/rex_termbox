defmodule ExTermbox.Bindings do
  @moduledoc """
  Bindings for the Termbox NIF library.

  This module loads the Native Implemented Functions (NIFs) compiled from C code
  and provides the Elixir interface to them.
  """

  @on_load :load_nif

  def load_nif do
    nif_path = Path.join([Application.app_dir(:rrex_termbox, "priv"), "termbox_bindings"])
    # Changed from libtermbox_bindings to termbox_bindings based on C filename
    # The actual library name might be platform-dependent (.so vs .dylib)
    # Erlang handles loading the correct extension.

    case :erlang.load_nif(nif_path, 0) do
      :ok ->
        :ok

      {:error, {:load_failed, reason}} ->
        IO.puts("Failed to load NIF library: #{reason}")
        :error

      {:error, :not_found} ->
        IO.puts("NIF library not found at path: #{nif_path}")
        :error

      other_error ->
        IO.puts("Error loading NIF: #{inspect(other_error)}")
        :error
    end
  end

  # --- NIF Function Stubs ---
  # These functions will be replaced by the actual NIFs when load_nif succeeds.
  # If load_nif fails, calling these will return :nif_not_loaded.

  def init, do: {:error, :nif_not_loaded}
  def shutdown, do: {:error, :nif_not_loaded}
  def width, do: {:error, :nif_not_loaded}
  def height, do: {:error, :nif_not_loaded}
  def clear, do: {:error, :nif_not_loaded}
  def set_clear_attributes(_fg, _bg), do: {:error, :nif_not_loaded}
  def present, do: {:error, :nif_not_loaded}
  def set_cursor(_x, _y), do: {:error, :nif_not_loaded}
  def change_cell(_x, _y, _ch, _fg, _bg), do: {:error, :nif_not_loaded}
  def select_input_mode(_mode), do: {:error, :nif_not_loaded}
  def select_output_mode(_mode), do: {:error, :nif_not_loaded}
  def start_polling(_pid), do: {:error, :nif_not_loaded}
  def stop_polling, do: {:error, :nif_not_loaded}
end 