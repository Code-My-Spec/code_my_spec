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
  alias CodeMySpec.Requirements.DelegateFiles
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type context :: %{
          files_by_component: %{Ecto.UUID.t() => [File.t()]},
          files_by_story: %{integer() => [File.t()]},
          files_by_project: [File.t()],
          files_by_path: %{String.t() => File.t()},
          problems_by_component: %{Ecto.UUID.t() => %{String.t() => integer()}},
          analysis_fresh: %{String.t() => boolean()},
          components: [Component.t()],
          components_by_id: %{Ecto.UUID.t() => Component.t()},
          children_by_parent: %{Ecto.UUID.t() => [Component.t()]},
          stories: [Story.t()],
          delegated_inputs: %{String.t() => [{term(), NaiveDateTime.t()}]},
          delegated_files: term()
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
      components_by_id: Map.new(components, &{&1.id, &1}),
      children_by_parent: Enum.group_by(components, & &1.parent_component_id),
      stories: stories,
      delegated_inputs: delegated_inputs(project_id),
      delegated_files: DelegateFiles.digest(scope)
    }
  end

  # Everything the graph's `:delegate` requirements read that nothing else here
  # loads: rules, criteria and questions (three_amigos_complete), personas
  # (personas_complete), and issues (issues_triaged / issues_resolved).
  #
  # Loaded for the fingerprint, not for the graph — no node reads them, and the
  # checkers still query for themselves. They are here so that
  # `GraphFingerprint` covers them, which is what a published graph needs
  # before anyone can safely treat it as current.
  #
  # `{id, updated_at}` rather than a content digest. The moduledoc on
  # `GraphFingerprint` rejects timestamps, and is right to for files:
  # `upsert_files/2` replaces rows on conflict, so a no-op sync bumps every
  # `updated_at` and the fingerprint would never settle. None of these five are
  # bulk-upserted — they are written one at a time through their contexts — so
  # here a timestamp is both stable across no-ops and strictly more sensitive
  # than hashing chosen columns, which is the failure mode that would matter.
  @delegated_tables ~w(bdd_rules criteria questions personas issues)

  defp delegated_inputs(project_id) do
    @delegated_tables
    |> Map.new(fn table -> {table, stamps(table, project_id)} end)
    |> Map.put("qa_attempts", qa_attempt_stamps(project_id))
  end

  # `qa_attempts` hangs off stories, not the project, so it cannot use `stamps/2`.
  # Read by `Qa.complete_check`, which backs `qa_complete`.
  defp qa_attempt_stamps(project_id) do
    Repo.all(
      from(a in "qa_attempts",
        join: s in "stories",
        on: s.id == a.story_id,
        where: s.project_id == type(^project_id, :binary_id),
        select: {a.id, a.updated_at},
        order_by: a.id
      )
    )
  end

  # Schemaless on purpose: this wants the fact that a row changed, not the row.
  # Going through each context would mean five different shapes and five more
  # things to keep in step with checkers that may start reading something else.
  defp stamps(table, project_id) do
    Repo.all(
      from(r in table,
        where: r.project_id == type(^project_id, :binary_id),
        select: {r.id, r.updated_at},
        order_by: r.id
      )
    )
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
