defmodule CodeMySpec.Requirements.Preloader do
  @moduledoc """
  Bulk-loads all data needed for requirement computation in minimal queries.

  Returns a context map that RequirementCalculator and RequirementGraph
  use instead of per-component queries. Eliminates N+1.
  """

  import Ecto.Query

  alias CodeMySpec.Analysis.{Fingerprint, Run, RunsRepository}
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
          files_by_path: %{String.t() => File.t()},
          problems_by_component: %{Ecto.UUID.t() => %{String.t() => integer()}},
          problems_by_story: %{integer() => %{String.t() => integer()}},
          problems_by_source: %{String.t() => integer()},
          analysis_fresh: %{String.t() => boolean()},
          components: [Component.t()],
          stories: [Story.t()]
        }

  @doc """
  Load all data for the project in ~6 queries.
  """
  @spec load(Scope.t()) :: context()
  def load(%Scope{active_project_id: project_id} = scope) do
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
    #
    # The pace gate. Only stories released for development project into the
    # requirement graph — a parked story produces no nodes at all, not even
    # Three Amigos. This is deliberately a filter rather than a requirement
    # node: a `ready_for_dev` node would surface as actionable work and the
    # agent would simply satisfy it, gating nothing.
    #
    # Parked stories stay reachable through the backlog tools, which query
    # Stories directly rather than going through the graph.
    stories =
      Story
      |> where([s], s.project_id == ^project_id and s.ready_for_dev == true)
      |> Repo.all()

    %{
      files_by_component: files_by_component,
      files_by_story: files_by_story,
      files_by_project: all_files,
      files_by_path: Map.new(all_files, &{&1.path, &1}),
      problems_by_component: problems_by_component,
      analysis_fresh: analysis_freshness(scope, all_files),
      components: components,
      stories: stories
    }
  end

  # Per-source freshness: does the latest completed full analysis run match
  # the current input fingerprint? Reuses the already-loaded file list, so
  # this is one ledger query plus in-memory hashing. `tests_passing` gates
  # on it — zero persisted problems only means "passing" when the results
  # are actually current for today's code.
  defp analysis_freshness(scope, all_files) do
    latest = RunsRepository.latest_full_runs(scope)

    Map.new(Run.sources(), fn source ->
      fresh? =
        case latest[source] do
          %Run{status: :completed, input_fingerprint: fp} when is_binary(fp) ->
            fp == Fingerprint.compute(all_files, Fingerprint.roles(source))

          _ ->
            false
        end

      {source, fresh?}
    end)
  end
end
