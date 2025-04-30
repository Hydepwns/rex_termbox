defmodule ExTermbox.Event do
  @moduledoc """
  Represents an event received from the termbox library.

  Events are polled by `ExTermbox.Server` and sent to the owner process.
  """

  @typedoc """
  The event structure.

  Fields:
  * `:type` - The type of event (e.g., `:key`, `:resize`, `:mouse`). Atom.
  * `:mod` - Modifier keys pressed (e.g., `:alt`). Atom or nil.
  * `:key` - The key pressed (e.g., `:f1`, `:arrow_up`, `:ctrl_a`). Atom or nil.
  * `:ch` - The character pressed (if applicable, Unicode codepoint). Integer or nil.
  * `:w` - New width (for resize events). Integer or nil.
  * `:h` - New height (for resize events). Integer or nil.
  * `:x` - Mouse x position (for mouse events). Integer or nil.
  * `:y` - Mouse y position (for mouse events). Integer or nil.
  """
  @type t :: %__MODULE__{
    type: atom(), # :key | :resize | :mouse | etc.
    mod: atom() | integer() | nil, # TODO: Finalize type based on NIF/mapping
    key: atom() | integer() | nil, # TODO: Finalize type based on NIF/mapping
    ch: integer() | nil,
    w: integer() | nil,
    h: integer() | nil,
    x: integer() | nil,
    y: integer() | nil
  }

  @enforce_keys [:type]
  defstruct [
    :type, # :key | :resize | :mouse | etc.
    mod: nil,
    key: nil,
    ch: nil,
    w: nil,
    h: nil,
    x: nil,
    y: nil
  ]

  # We might add helper functions here later to interpret event data
  # if the NIF returns raw integers/atoms that need mapping.
end
