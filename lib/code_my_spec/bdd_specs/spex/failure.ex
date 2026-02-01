defmodule CodeMySpec.BddSpecs.Spex.Failure do
  @moduledoc """
  Struct representing a single test failure with BDD context.
  """

  alias CodeMySpec.BddSpecs.Spex.{Step, Error}

  @type t :: %__MODULE__{
          spex: String.t(),
          scenario: String.t() | nil,
          steps: [Step.t()],
          error: Error.t() | nil
        }

  defstruct [
    :spex,
    :scenario,
    :error,
    steps: []
  ]
end
