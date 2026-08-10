defmodule CodeMySpec.Requirements.Preloader do
  @moduledoc """
  Bulk-loads all data needed for requirement computation in minimal queries.

  Returns a context map that RequirementCalculator and RequirementGraph
  use instead of per-component queries. Eliminates N+1.
  """

  import Ecto.Query

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Analysis.{Fingerprint, Run, RunsRepository}
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Files.File
  alias CodeMySpec.Personas.{Persona, PersonaStory}
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Repo
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
          rules_by_story: %{integer() => [Rule.t()]},
          questions_by_story: %{integer() => [Question.t()]},
          criteria_by_story: %{integer() => [Criterion.t()]},
          personas_by_story: %{integer() => [Persona.t()]},
          qa_latest_by_story: %{integer() => QaAttempt.t()},
          delegated_inputs: %{String.t() => [{term(), NaiveDateTime.t()}]}
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

    story_ids = Enum.map(stories, & &1.id)

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
      rules_by_story: rules_by_story(project_id),
      questions_by_story: questions_by_story(project_id),
      criteria_by_story: criteria_by_story(story_ids),
      personas_by_story: personas_by_story(story_ids),
      qa_latest_by_story: qa_latest_by_story(story_ids),
      delegated_inputs: delegated_inputs(project_id)
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

  # The four collections `BddRulesChecker` reads, batched.
  #
  # `compute_story_nodes/3` loops every ready story and `run_delegate/5` hands
  # the checker a scope and a story and nothing else, so the checker queried per
  # story: personas, rules, criteria and questions, four round trips each. On a
  # project with 76 ready stories that is 304 queries inside one graph
  # computation, and the graph is recomputed on every stop hook.
  #
  # Four queries here instead. They are four rather than one repeated because
  # the linkage genuinely differs: rules and questions carry `project_id`,
  # criteria carry only `story_id`, and personas hang off a join table.
  defp rules_by_story(project_id) do
    Rule
    |> where([r], r.project_id == ^project_id and not is_nil(r.story_id))
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
  end

  defp questions_by_story(project_id) do
    Question
    |> where([q], q.project_id == ^project_id and not is_nil(q.story_id))
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
  end

  # No `project_id` on a criterion — it is reachable only through its story, so
  # the story ids are the scope.
  defp criteria_by_story(story_ids) do
    Criterion
    |> where([c], c.story_id in ^story_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
  end

  defp personas_by_story(story_ids) do
    from(ps in PersonaStory,
      join: p in Persona,
      on: p.id == ps.persona_id,
      where: ps.story_id in ^story_ids,
      select: {ps.story_id, p}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The newest QA attempt per story, invalidations preloaded — exactly what
  # `QaAttempts.complete?/2` fetches one story at a time.
  #
  # The whole attempt rather than a boolean: deciding pass/fail is the Qa
  # context's judgement, and duplicating `status == :pass and invalidations == []`
  # here would be two places to change and one place to forget.
  #
  # Ordered by the database on the same keys `complete?/2` uses, then taken
  # first-per-group: `Enum.group_by/2` preserves encounter order, so the head of
  # each group is that story's newest attempt. Ordering in Elixir would mean
  # comparing `{inserted_at, id}` tuples by hand, and a `DISTINCT ON` would not
  # port to the SQLite side.
  defp qa_latest_by_story(story_ids) do
    QaAttempt
    |> where([a], a.story_id in ^story_ids)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> preload(:invalidations)
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
    |> Map.new(fn {story_id, [latest | _]} -> {story_id, latest} end)
  end

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
