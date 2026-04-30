defmodule CodeMySpec.Requirements.CheckerResult do
  @moduledoc """
  Adapts a checker's `{boolean(), map()}` return into the standard agent
  task evaluation tuple consumed by the stop hook.

  Every `:delegate` requirement checker (`PersonasChecker`, `StoriesChecker`,
  `BddRulesChecker`, `IssuesChecker`, etc.) returns `{satisfied?, detail}`.
  Agent tasks turn that into one of:

    * `{:ok, :valid}` — satisfied
    * `{:ok, :invalid, reason}` — unsatisfied with a human-readable reason

  This module collapses the three-clause shape match each task module
  used to repeat verbatim.
  """

  @type checker_return :: {boolean(), map()}
  @type evaluation :: {:ok, :valid} | {:ok, :invalid, String.t()}

  @spec to_evaluation(checker_return()) :: evaluation()
  def to_evaluation({true, _detail}), do: {:ok, :valid}
  def to_evaluation({false, %{reason: reason}}) when is_binary(reason), do: {:ok, :invalid, reason}
  def to_evaluation({false, detail}), do: {:ok, :invalid, inspect(detail)}
end
