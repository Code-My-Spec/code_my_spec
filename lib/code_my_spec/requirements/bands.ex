defmodule CodeMySpec.Requirements.Bands do
  @moduledoc """
  Where the project stands, for the timeline: the project gates either side of
  where stories join, the stories step by step, the components, and the issues.

  Which side of the join a gate is on comes from the project template and
  `RequirementGraph.story_join/0`, so it is fixed per requirement name — no
  graph is loaded to find it. The counts are grouped queries over the stored
  rows at the scope's vantage, cheap enough to read wherever the timeline is
  drawn.
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

  @type story :: %{
          number: integer() | nil,
          title: String.t() | nil,
          done: non_neg_integer(),
          working: non_neg_integer(),
          issues: non_neg_integer(),
          none: non_neg_integer()
        }

  @type t :: %{
          satisfied: MapSet.t(String.t()),
          late_names: MapSet.t(String.t()),
          stories: [story()],
          components: {non_neg_integer(), non_neg_integer()},
          issues: %{open: non_neg_integer(), resolved: non_neg_integer()}
        }

  @doc "Project gates from where stories join onward."
  def late_project_names do
    definitions = RequirementDefinitionData.project_graph()
    by_id = Map.new(definitions, &{&1.id, &1})
    join = Enum.find(definitions, &(&1.name == RequirementGraph.story_join()))

    definitions
    |> Enum.filter(&(&1 == join or reaches?(&1, join.id, by_id, MapSet.new())))
    |> MapSet.new(& &1.name)
  end

  @doc "The story template's steps, prerequisites first."
  def story_step_names do
    definitions = RequirementDefinitionData.story_graph()
    by_id = Map.new(definitions, &{&1.id, &1})

    definitions
    |> Enum.with_index()
    |> Enum.sort_by(fn {definition, index} -> {depth(definition, by_id), index} end)
    |> Enum.map(fn {definition, _index} -> definition.name end)
  end

  @doc """
  Where the project stands. Each story is its steps counted four ways: done
  when satisfied; held by issues when not and the story has any open; working
  when its own earlier steps are done; not started otherwise. Furthest reached
  first.
  """
  @spec read(Scope.t()) :: t()
  def read(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    vantage = Projection.vantage(scope)

    %{
      satisfied: satisfied_gates(project_id, vantage),
      late_names: late_project_names(),
      stories: stories(project_id, vantage),
      components: component_counts(project_id, vantage),
      issues: issue_counts(project_id)
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

  defp stories(project_id, vantage) do
    rows =
      Node
      |> join(:inner, [r], s in Story, on: s.id == r.story_id)
      |> where([_r, s], s.project_id == ^project_id)
      |> at_vantage(vantage)
      |> select([r, s], {{r.story_id, s.number, s.title}, r.name, r.satisfied})
      |> Repo.all()

    with_issues = stories_with_open_issues(project_id)
    prereqs = story_prerequisite_names()
    steps = story_step_names()

    rows
    |> Enum.reduce(%{}, fn {story, name, satisfied}, acc ->
      Map.update(acc, story, done_set(name, satisfied), &add_done(&1, name, satisfied))
    end)
    |> Enum.map(fn {{id, number, title}, done} ->
      issues? = MapSet.member?(with_issues, id)

      steps
      |> Enum.map(&step_status(&1, done, prereqs[&1], issues?))
      |> Enum.frequencies()
      |> then(&Map.merge(%{done: 0, working: 0, issues: 0, none: 0}, &1))
      |> Map.merge(%{number: number, title: title})
    end)
    # Furthest reached first, then most done: grey only grows toward the end,
    # so the columns' tops fall away in one line.
    |> Enum.sort_by(&{&1.none, -&1.done, &1.issues, &1.number})
  end

  defp done_set(name, true), do: MapSet.new([name])
  defp done_set(_name, _satisfied), do: MapSet.new()

  defp add_done(set, name, true), do: MapSet.put(set, name)
  defp add_done(set, _name, _satisfied), do: set

  defp step_status(name, done, prereqs, issues?) do
    cond do
      MapSet.member?(done, name) -> :done
      issues? -> :issues
      MapSet.subset?(prereqs, done) -> :working
      true -> :none
    end
  end

  # Each story step's own prerequisites, by name — the story-internal ones; the
  # components feeding `ready_for_qa` are the components bar's business.
  defp story_prerequisite_names do
    definitions = RequirementDefinitionData.story_graph()
    names = Map.new(definitions, &{&1.id, &1.name})

    Map.new(definitions, fn definition ->
      {definition.name,
       definition.prerequisites |> Enum.flat_map(&List.wrap(names[&1])) |> MapSet.new()}
    end)
  end

  defp stories_with_open_issues(project_id) do
    Issue
    |> where([i], i.project_id == ^project_id and i.status in [:incoming, :accepted])
    |> where([i], not is_nil(i.story_id))
    |> distinct(true)
    |> select([i], i.story_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp component_counts(project_id, vantage) do
    Node
    |> join(:inner, [r], c in Component, on: c.id == r.component_id)
    |> where([_r, c], c.project_id == ^project_id)
    |> at_vantage(vantage)
    |> select([r], {count(r.id) |> filter(r.satisfied), count(r.id)})
    |> Repo.one()
  end

  defp issue_counts(project_id) do
    counts =
      Issue
      |> where([i], i.project_id == ^project_id)
      |> group_by([i], i.status)
      |> select([i], {i.status, count(i.id)})
      |> Repo.all()
      |> Map.new()

    %{
      open: Map.get(counts, :incoming, 0) + Map.get(counts, :accepted, 0),
      resolved: Map.get(counts, :resolved, 0)
    }
  end

  defp depth(definition, by_id) do
    definition.prerequisites
    |> Enum.flat_map(&List.wrap(by_id[&1]))
    |> Enum.map(&(depth(&1, by_id) + 1))
    |> Enum.max(fn -> 0 end)
  end

  defp reaches?(definition, target, by_id, seen) do
    Enum.any?(definition.prerequisites, fn id ->
      id == target or
        (not MapSet.member?(seen, id) and Map.has_key?(by_id, id) and
           reaches?(by_id[id], target, by_id, MapSet.put(seen, id)))
    end)
  end
end
