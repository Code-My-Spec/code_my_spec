defmodule CodeMySpec.BddSpecs.Spex.Failure do
  @moduledoc """
  Struct representing a single test failure with BDD context.

  `spec_file` is the spec this failure came from, which is not the same
  question as `error.file` — that one is where the exception was raised, and for
  a provider call from a LiveView process the two are on different stacks
  entirely. Kept apart deliberately: `Runners.spex_location/1` prefers a
  `_spex.exs` stacktrace frame over `error.file`, and collapsing them would
  undo the rule that stopped failures being filed against
  `lib/req_cassette/plug.ex` (`cd2a0db4`).
  """

  alias CodeMySpec.BddSpecs.Spex.{Error, Step}

  @type t :: %__MODULE__{
          spex: String.t(),
          scenario: String.t() | nil,
          spec_file: String.t() | nil,
          steps: [Step.t()],
          error: Error.t() | nil
        }

  defstruct [
    :spex,
    :scenario,
    :spec_file,
    :error,
    steps: []
  ]
end
