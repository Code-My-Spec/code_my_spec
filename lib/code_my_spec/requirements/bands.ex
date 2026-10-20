defmodule CodeMySpec.Requirements.Bands do
  @moduledoc """
  The project's progress in the five bands the graph runs through: the serial
  project gates before stories join, each story's work before components join,
  the components, each story's work after, and the project gates after.

  Which band a requirement is in comes from the templates and the two places
  `RequirementGraph` joins entities (`component_join/0`, `story_join/0`), so it
  is fixed per requirement name — no graph is loaded to find it. The counts are
  grouped queries over the stored rows at the scope's vantage, so this is cheap
  enough to read wherever the timeline is drawn.
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type tally :: %{
          done: non_neg_integer(),
          partial: non_neg_integer(),
          issues: non_neg_integer(),
          none: non_neg_integer()
        }

  @type t :: %{
          satisfied: MapSet.t(String.t()),
          late_names: MapSet.t(String.t()),
          pre_stories: tally(),
          components: {non_neg_integer(), non_neg_integer()},
          post_stories: tally()
        }

  @doc "Project gates from where stories join onward."
  def late_project_names,
    do: from_join(RequirementDefinitionData.project_graph(), RequirementGraph.story_join())

  @doc "Story requirements from where components join onward."
  def post_story_names,
    do: from_join(RequirementDefinitionData.story_graph(), RequirementGraph.component_join())

  @doc """
  Where the project stands, band by band. A story counts as done in a band
  when every one of its requirements there is satisfied, partial when some
  are, and — after components join — as having issues when it has any open.
  """
  @spec read(Scope.t()) :: t()
  def read(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    vantage = Projection.vantage(scope)
    post = post_story_names()

    %{
      satisfied: satisfied_gates(project_id, vantage),
      late_names: late_project_names(),
      pre_stories: tally(story_counts(project_id, vantage, post, false), %{}),
      components: component_counts(project_id, vantage),
      post_stories: tally(story_counts(project_id, vantage, post, true), open_issues(project_id))
    }
  end

  defp at_vantage(query, nil), do: where(query, [r], is_nil(r.working_copy_id))
  defp at_vantage(query, vantage), do: where(query, [r], r.working_copy_id == ^vantage)

  defp satisfied_gates(project_id, vantage) do
    Node
    |> where([r], r.project_id == ^project_id and r.satisfied)
    |> where([r], is_nil(r.story_id) and is_nil(r.component_id) and is_nil(r.issue_id))
    |> at_vantage(vantage)
    |> select([r], r.name)
    |> Repo.all()
    |> MapSet.new()
  end

  # `[{story_id, satisfied, total}]` for one side of the component join.
  defp story_counts(project_id, vantage, post, post?) do
    post = MapSet.to_list(post)

    Node
    |> join(:inner, [r], s in Story, on: s.id == r.story_id)
    |> where([_r, s], s.project_id == ^project_id)
    |> where_side(post, post?)
    |> at_vantage(vantage)
    |> group_by([r], r.story_id)
    |> select([r], {r.story_id, count(r.id) |> filter(r.satisfied), count(r.id)})
    |> Repo.all()
  end

  defp where_side(query, post, true), do: where(query, [r], r.name in ^post)
  defp where_side(query, post, false), do: where(query, [r], r.name not in ^post)

  defp component_counts(project_id, vantage) do
    Node
    |> join(:inner, [r], c in Component, on: c.id == r.component_id)
    |> where([_r, c], c.project_id == ^project_id)
    |> at_vantage(vantage)
    |> select([r], {count(r.id) |> filter(r.satisfied), count(r.id)})
    |> Repo.one()
  end

  defp open_issues(project_id) do
    Issue
    |> where([i], i.project_id == ^project_id and i.status in [:incoming, :accepted])
    |> where([i], not is_nil(i.story_id))
    |> group_by([i], i.story_id)
    |> select([i], {i.story_id, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp tally(counts, issues) do
    Enum.reduce(counts, %{done: 0, partial: 0, issues: 0, none: 0}, fn {story_id, done, total},
                                                                       acc ->
      Map.update!(acc, status(done, total, Map.get(issues, story_id, 0)), &(&1 + 1))
    end)
  end

  defp status(_done, _total, open) when open > 0, do: :issues
  defp status(done, total, _open) when total > 0 and done == total, do: :done
  defp status(done, _total, _open) when done > 0, do: :partial
  defp status(_done, _total, _open), do: :none

  # The join and every requirement whose prerequisites reach it.
  defp from_join(definitions, join) do
    by_id = Map.new(definitions, &{&1.id, &1})
    start = Enum.find(definitions, &(&1.name == join))

    definitions
    |> Enum.filter(&(&1 == start or reaches?(&1, start.id, by_id, MapSet.new())))
    |> MapSet.new(& &1.name)
  end

  defp reaches?(definition, target, by_id, seen) do
    Enum.any?(definition.prerequisites, fn id ->
      id == target or
        (not MapSet.member?(seen, id) and Map.has_key?(by_id, id) and
           reaches?(by_id[id], target, by_id, MapSet.put(seen, id)))
    end)
  end
end
