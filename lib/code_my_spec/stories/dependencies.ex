defmodule CodeMySpec.Stories.Dependencies do
  @moduledoc "Directed, project-scoped links between stories."

  import Ecto.Query

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  def add(%Scope{} = scope, number, builds_on) do
    mutate(scope, number, builds_on, fn story, target ->
      if story.id == target.id, do: Repo.rollback("a story cannot build on itself")

      edges = edges(scope)
      adjacency = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))

      case path(adjacency, target.id, story.id, MapSet.new()) do
        nil ->
          Repo.insert_all(
            "story_dependencies",
            [%{story_id: story.id, builds_on_id: target.id}],
            on_conflict: :nothing
          )

          :ok

        route ->
          numbers =
            Story
            |> where([s], s.project_id == ^scope.active_project_id)
            |> select([s], {s.id, s.number})
            |> Repo.all()
            |> Map.new()

          loop = Enum.map_join([story.id | route], " -> ", &to_string(numbers[&1]))
          Repo.rollback("Story dependency cycle: " <> loop)
      end
    end)
  end

  def remove(%Scope{} = scope, number, builds_on) do
    mutate(scope, number, builds_on, fn story, target ->
      from(d in "story_dependencies",
        where: d.story_id == ^story.id and d.builds_on_id == ^target.id
      )
      |> Repo.delete_all()

      :ok
    end)
  end

  def list(%Scope{} = scope, story_id) do
    links = edges(scope)
    upstream = for {^story_id, target} <- links, do: target
    downstream = for {source, ^story_id} <- links, do: source

    stories =
      Story
      |> where(
        [s],
        s.project_id == ^scope.active_project_id and s.id in ^(upstream ++ downstream)
      )
      |> order_by([s], asc: s.number)
      |> Repo.all()

    %{
      builds_on: Enum.filter(stories, &(&1.id in upstream)),
      built_on_by: Enum.filter(stories, &(&1.id in downstream))
    }
  end

  # Every edge writer takes the same project row lock before reading the graph.
  # Locking just the endpoints would allow disjoint simultaneous edges to close a cycle.
  defp mutate(scope, number, builds_on, operation) do
    Repo.transaction(fn ->
      project =
        Project
        |> where([p], p.id == ^scope.active_project_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if is_nil(project), do: Repo.rollback("Project not found")
      story = fetch(scope, number)
      target = fetch(scope, builds_on)
      operation.(story, target)
    end)
  end

  defp fetch(scope, number) do
    case Repo.get_by(Story, project_id: scope.active_project_id, number: number) do
      nil -> Repo.rollback("Story not found in this project")
      story -> story
    end
  end

  defp edges(scope) do
    from(d in "story_dependencies",
      join: source in Story,
      on: source.id == d.story_id,
      join: target in Story,
      on: target.id == d.builds_on_id,
      where:
        source.project_id == ^scope.active_project_id and
          target.project_id == ^scope.active_project_id,
      order_by: [asc: target.number],
      select: {d.story_id, d.builds_on_id}
    )
    |> Repo.all()
  end

  defp path(_graph, target, target, _seen), do: [target]

  defp path(graph, current, target, seen) do
    if MapSet.member?(seen, current) do
      nil
    else
      seen = MapSet.put(seen, current)

      Enum.find_value(Map.get(graph, current, []), fn next ->
        case path(graph, next, target, seen) do
          nil -> nil
          route -> [current | route]
        end
      end)
    end
  end
end
