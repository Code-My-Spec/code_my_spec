defmodule CodeMySpec.Requirements.Bands do
  @moduledoc """
  Where the project stands, for the timeline: the project gates either side of
  where stories join, the stories step by step, the components, and the issues.

  Which side of the join a gate is on comes from the project template and
  `RequirementGraph.story_join/0`, so it is fixed per requirement name — no
  graph is loaded to find it. The counts are over the graph served at the
  scope's vantage (`RequirementGraph.served_graph/2`).
  """

  import Ecto.Query

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type story :: %{
          id: integer(),
          working_copy_id: String.t() | nil,
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
          story_counts: %{
            done: non_neg_integer(),
            backlog: non_neg_integer(),
            retired: non_neg_integer()
          },
          components: %{
            done: non_neg_integer(),
            not_done: non_neg_integer(),
            unspecified: non_neg_integer()
          },
          issues: %{
            resolved: non_neg_integer(),
            dismissed: non_neg_integer(),
            open: non_neg_integer()
          }
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
  Where the project stands. The stories in progress — ready for development,
  not retired, with any requirement unsatisfied — are each their steps counted four ways: done
  when satisfied; held by issues when not and the story has any open; working
  when its own earlier steps are done; not started otherwise. Furthest reached
  first.
  """
  @spec read(Scope.t()) :: t()
  def read(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    ctx = RequirementGraph.read_context(scope)
    {nodes, _edges} = RequirementGraph.served_graph(scope, ctx)
    by_type = Enum.group_by(nodes, & &1.entity_type)
    {in_progress, done} = stories(Map.get(by_type, "story", []), ctx, project_id)

    %{
      satisfied: satisfied_gates(Map.get(by_type, "project", [])),
      late_names: late_project_names(),
      stories: in_progress,
      story_counts: Map.put(story_counts(project_id), :done, done),
      components: component_counts(Map.get(by_type, "component", []), ctx),
      issues: issue_counts(project_id)
    }
  end

  defp satisfied_gates(project_nodes),
    do: for(%{satisfied: true, name: name} <- project_nodes, into: MapSet.new(), do: name)

  # A story is done when every one of its requirements is satisfied at this
  # vantage, promoted or not; anything else is in progress and on the chart.
  # Returns the in-progress stories and the count of done ones. The read
  # context holds the ready stories this vantage sees; retired ones are off the
  # chart.
  defp stories(story_nodes, ctx, project_id) do
    live = for story <- ctx.stories, is_nil(story.retired_at), into: %{}, do: {story.id, story}

    rows =
      for %{entity_id: id, name: name, satisfied: satisfied} <- story_nodes,
          story = live[id],
          do: {{id, story.number, story.title, story.working_copy_id}, name, satisfied}

    {done, in_progress} =
      rows
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.split_with(fn {_story, reqs} -> Enum.all?(reqs, &elem(&1, 2)) end)

    {in_progress |> Enum.flat_map(&elem(&1, 1)) |> in_progress_bars(project_id), length(done)}
  end

  defp in_progress_bars(rows, project_id) do
    with_issues = stories_with_open_issues(project_id)
    prereqs = story_prerequisite_names()
    steps = story_step_names()

    rows
    |> Enum.reduce(%{}, fn {story, name, satisfied}, acc ->
      Map.update(acc, story, done_set(name, satisfied), &add_done(&1, name, satisfied))
    end)
    |> Enum.map(fn {{id, number, title, copy_id}, done} ->
      issues? = MapSet.member?(with_issues, id)

      steps
      |> Enum.map(&step_status(&1, done, prereqs[&1], issues?))
      |> Enum.frequencies()
      |> then(&Map.merge(%{done: 0, working: 0, issues: 0, none: 0}, &1))
      |> Map.merge(%{id: id, working_copy_id: copy_id, number: number, title: title})
    end)
    # Furthest reached first, then most done: grey only grows toward the end,
    # so the columns' tops fall away in one line.
    |> Enum.sort_by(&{&1.none, -&1.done, &1.issues, &1.number})
  end

  # The other stories outside the chart: not yet ready for development
  # (backlog) and retired. Done is counted from the requirements in `stories/2`.
  defp story_counts(project_id) do
    Story
    |> where([s], s.project_id == ^project_id)
    |> select([s], %{
      backlog: count(s.id) |> filter(not s.ready_for_dev and is_nil(s.retired_at)),
      retired: count(s.id) |> filter(not is_nil(s.retired_at))
    })
    |> Repo.one()
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

  # Planned components (`:authored`) done or not — every requirement satisfied
  # — and the ones found on disk that nobody planned (`:discovered`).
  defp component_counts(component_nodes, ctx) do
    provenance =
      component_nodes
      |> Enum.group_by(& &1.entity_id)
      |> Enum.map(fn {id, nodes} ->
        {ctx.components_by_id[id].provenance, Enum.all?(nodes, & &1.satisfied)}
      end)

    %{
      done: Enum.count(provenance, &(&1 == {:authored, true})),
      not_done: Enum.count(provenance, &(&1 == {:authored, false})),
      unspecified: Enum.count(provenance, &match?({:discovered, _}, &1))
    }
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
      resolved: Map.get(counts, :resolved, 0),
      dismissed: Map.get(counts, :dismissed, 0),
      open: Map.get(counts, :incoming, 0) + Map.get(counts, :accepted, 0)
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
