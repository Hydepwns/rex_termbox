defmodule ExTermbox.Position do
  @moduledoc """
  Represents a position on the screen by encoding a pair of cartesian
  coordinates. The origin is the top-left-most character on the screen
  `(0, 0)`, while x and y increase from left to right and top to bottom,
  respectively.
  """

  alias __MODULE__, as: Position

  @enforce_keys [:x, :y]
  defstruct [:x, :y]

  @type t :: %__MODULE__{x: non_neg_integer, y: non_neg_integer}

  @doc """
  Translates (shifts) a position by some delta x and y.

  Returns a new `%Position{}`.

  ## Examples

      iex> ExTermbox.Position.translate(%ExTermbox.Position{x: 0, y: 0}, 1, 2)
      %ExTermbox.Position{x: 1, y: 2}
      iex> ExTermbox.Position.translate(%ExTermbox.Position{x: 10, y: 0}, -1, 0)
      %ExTermbox.Position{x: 9, y: 0}

  """
  @spec translate(t, integer, integer) :: t
  def translate(%Position{x: x, y: y}, dx, dy),
    do: %Position{x: x + dx, y: y + dy}

  @doc """
  Translates a position by a delta x.

  Returns a new `%Position{}`.

  ## Examples

      iex> ExTermbox.Position.translate_x(%ExTermbox.Position{x: 0, y: 0}, 2)
      %ExTermbox.Position{x: 2, y: 0}
      iex> ExTermbox.Position.translate_x(%ExTermbox.Position{x: 2, y: 0}, -1)
      %ExTermbox.Position{x: 1, y: 0}

  """
  @spec translate_x(t, integer) :: t
  def translate_x(pos = %Position{y: _y}, dx), do: translate(pos, dx, 0)

  @doc """
  Translates a position by a delta y.

  Returns a new `%Position{}`.

  ## Examples

      iex> ExTermbox.Position.translate_y(%ExTermbox.Position{x: 0, y: 0}, 2)
      %ExTermbox.Position{x: 0, y: 2}
      iex> ExTermbox.Position.translate_y(%ExTermbox.Position{x: 0, y: 2}, -1)
      %ExTermbox.Position{x: 0, y: 1}

  """
  @spec translate_y(t, integer) :: t
  def translate_y(pos = %Position{x: _x}, dy), do: translate(pos, 0, dy)
end
