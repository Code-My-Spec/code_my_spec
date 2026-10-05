defmodule CodeMySpec.AgentPerformance.Throughput do
  @moduledoc """
  Story throughput per team over a period: how many stories a team
  promoted.

  A team is the working copy a story was built on. `promoted_at` is
  approximated from the story's own `updated_at` at the moment
  `promoted_version` is set -- see `CycleTime` for why nothing stamps
  that moment more directly.
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
    |> Stories.list_project_stories()
    |> Enum.filter(&promoted_in_period?(&1, since))
    |> Enum.group_by(& &1.working_copy_id)
    |> Map.new(fn {working_copy_id, stories} -> {working_copy_id, length(stories)} end)
  end

  defp promoted_in_period?(%Story{promoted_version: nil}, _since), do: false
  defp promoted_in_period?(%Story{}, nil), do: true

  defp promoted_in_period?(%Story{updated_at: at}, since),
    do: DateTime.compare(at, since) != :lt
end
