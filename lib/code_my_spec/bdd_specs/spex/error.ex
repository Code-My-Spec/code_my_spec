defmodule CodeMySpec.BddSpecs.Spex.Error do
  @moduledoc """
  Struct representing the error details of a failure.
  """

  @type t :: %__MODULE__{
          message: String.t(),
          file: String.t() | nil,
          line: integer() | nil,
          stacktrace: [map()],
          left: String.t() | nil,
          right: String.t() | nil
        }

  defstruct [
    :message,
    :file,
    :line,
    :left,
    :right,
    stacktrace: []
  ]
end
