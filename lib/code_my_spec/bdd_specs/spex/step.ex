defmodule CodeMySpec.BddSpecs.Spex.Step do
  @moduledoc """
  Struct representing a BDD step executed during the test.
  """

  @type t :: %__MODULE__{
          type: String.t(),
          description: String.t(),
          status: String.t()
        }

  defstruct [
    :type,
    :description,
    :status
  ]
end
