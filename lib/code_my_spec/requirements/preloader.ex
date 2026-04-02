defmodule CodeMySpec.Requirements.Preloader do
  @moduledoc """
  Bulk-loads all data needed for requirement computation in minimal queries.

  Returns a context map that RequirementCalculator and RequirementGraph
  use instead of per-component queries. Eliminates N+1.
  """

  import Ecto.Query

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files.File
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type context :: %{
          files_by_component: %{Ecto.UUID.t() => [File.t()]},
          files_by_story: %{integer() => [File.t()]},
          files_by_project: [File.t()],
          problems_by_component: %{Ecto.UUID.t() => %{String.t() => integer()}},
          components: [Component.t()],
          stories: [Story.t()]
        }

  @doc """
  Load all data for the project in ~5 queries.
  """
  @spec load(Scope.t()) :: context()
  def load(%Scope{active_project_id: project_id}) do
    # 1. All components with deps and children preloaded
    components =
      Component
      |> where([c], c.project_id == ^project_id)
      |> preload([:dependencies, :child_components])
      |> Repo.all()

    # 2. All files grouped by component and story
    all_files =
      File
      |> where([f], f.project_id == ^project_id)
      |> Repo.all()

    files_by_component =
      all_files
      |> Enum.filter(& &1.component_id)
      |> Enum.group_by(& &1.component_id)

    files_by_story =
      all_files
      |> Enum.filter(& &1.story_id)
      |> Enum.group_by(& &1.story_id)

    # 3. Problem counts by component and source
    problem_counts =
      Problem
      |> where([p], p.project_id == ^project_id and not is_nil(p.component_id))
      |> group_by([p], [p.component_id, p.source])
      |> select([p], {p.component_id, p.source, count(p.id)})
      |> Repo.all()

    problems_by_component =
      Enum.reduce(problem_counts, %{}, fn {comp_id, source, count}, acc ->
        Map.update(acc, comp_id, %{source => count}, &Map.put(&1, source, count))
      end)

    # 4. Stories
    stories =
      Story
      |> where([s], s.project_id == ^project_id)
      |> Repo.all()

    %{
      files_by_component: files_by_component,
      files_by_story: files_by_story,
      files_by_project: all_files,
      problems_by_component: problems_by_component,
      components: components,
      stories: stories
    }
  end
end
