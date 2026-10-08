defmodule CodeMySpec.AgentPerformance.Throughput do
  @moduledoc """
  Story throughput per team over a period: how many stories a team
  promoted.

  A team is the copy recorded at promotion, independent of current assignment.
  Older stories without a promotion stamp retain the legacy attribution.
  """

  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Promoted story counts for the period, keyed by the working copy
  (team) that promoted them. `since` restricts to stories promoted at or
  after it; omit for all time.
  """
  @spec by_team(Scope.t(), DateTime.t() | nil) :: %{Ecto.UUID.t() => non_neg_integer()}
  def by_team(%Scope{} = scope, since \\ nil) do
    scope
    |> list_stories()
    |> Enum.filter(&promoted_in_period?(&1, since))
    |> Enum.group_by(&(&1.promoted_working_copy_id || &1.working_copy_id))
    |> Map.new(fn {working_copy_id, stories} -> {working_copy_id, length(stories)} end)
  end

  defp promoted_in_period?(%Story{promoted_version: nil}, _since), do: false
  defp promoted_in_period?(%Story{}, nil), do: true

  defp promoted_in_period?(%Story{} = story, since),
    do: DateTime.compare(story.promoted_at || story.updated_at, since) != :lt

  defp list_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
    end
  end
end
