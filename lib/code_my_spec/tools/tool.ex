defmodule CodeMySpec.Tools.Tool do
  @moduledoc """
  One agent-facing tool. Implemented in the domain the tool acts on.

  `params/0` is a Peri schema, written out as data:

      %{slug: {:required, {:meta, :string, [description: "Persona slug"]}}}

  `call/2` gets the cast parameters (atom keys) and the caller's context, and
  answers in the text an agent reads. `script_result/2`, when a tool has it,
  answers a script with data instead.
  """

  alias CodeMySpec.Tools

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback params() :: map()
  @callback call(params :: map(), Tools.context()) :: result()
  @callback script_result(params :: map(), Tools.context()) ::
              {:ok, term()} | {:error, String.t()}

  @optional_callbacks script_result: 2
end
