defmodule CodeMySpec.CodeMode.Result do
  @moduledoc """
  What an evaluation answers with: the script's value, what it printed, and any
  error.

  All three, always, and that is the point. A result that carried only the
  value would make a script that failed halfway indistinguishable from one that
  returned nothing — and under the no-transaction decision, a script that fails
  halfway has already written. What it printed on the way is how its author
  works out which half.
  """

  @enforce_keys [:value]
  defstruct [:value, :error, printed: []]

  @type error :: %{kind: atom(), message: String.t()}

  @type t :: %__MODULE__{
          value: term(),
          printed: [String.t()],
          error: error() | nil
        }

  @doc "A successful run."
  @spec ok(term(), [String.t()]) :: t()
  def ok(value, printed \\ []), do: %__MODULE__{value: value, printed: printed}

  @doc """
  A failed run, keeping whatever it printed first.

  `kind` separates the failures that mean different things — a script that will
  not compile, one that broke a limit, one whose tool crashed, one that ran too
  long. An agent reading `:timeout` retries; one reading `:compile` rewrites.
  """
  @spec error(atom(), String.t(), [String.t()]) :: t()
  def error(kind, message, printed \\ []) do
    %__MODULE__{value: nil, printed: printed, error: %{kind: kind, message: message}}
  end

  @doc "Whether the run failed."
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{error: nil}), do: false
  def failed?(%__MODULE__{}), do: true
end
