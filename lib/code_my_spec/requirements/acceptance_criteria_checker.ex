defmodule CodeMySpec.Requirements.AcceptanceCriteriaChecker do
  @moduledoc """
  Delegate checker for the `acceptance_criteria_exist` requirement on
  `story_graph`.

  A story is considered to have acceptance criteria when at least one
  `Criterion` row is present for the given story. Returns
  `{boolean(), map()}` per the checker contract (see `IssuesChecker`,
  `PersonasChecker`).

  Failure reason directs the agent toward `add_criterion` so the
  stop-hook feedback can prompt the next turn surgically.
  """

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{} = scope, %Story{id: story_id}) when not is_nil(story_id) do
    criteria = AcceptanceCriteria.list_story_criteria(scope, story_id)

    if criteria == [] do
      {false,
       %{
         reason:
           "Story has no acceptance criteria — call `add_criterion` to capture at least one."
       }}
    else
      {true, %{status: "#{length(criteria)} criterion/criteria present"}}
    end
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active scope or invalid story entity — cannot check criteria."}}
  end
end
