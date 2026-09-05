defmodule CodeMySpec.Requirements.Preloader do
  @moduledoc """
  Bulk-loads all data needed for requirement computation in minimal queries.

  Returns a context map that RequirementCalculator and RequirementGraph
  use instead of per-component queries. Eliminates N+1.
  """

  import Ecto.Query

  require Logger

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Analysis.{Fingerprint, Run, RunsRepository}
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Deploys.Deploy
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
          uat_deploy_by_story: %{integer() => Deploy.t()},
          delegated_inputs: %{String.t() => [{term(), NaiveDateTime.t()}]}
        }

  @doc """
  Load all data for the project in ~6 queries.

  ## One checkout, or all of them

  Every working copy files its own row per path, so a scope naming a harness
  gets that checkout's tree and a scope naming none gets all of them blended.

  Both are wanted, by different callers:

    * **an agent** always has a working copy — the hook carries `X-Harness-Id`
      — and must see only it. Blended, 308 `(component, role)` pairs read as
      satisfied here by files that exist only in another checkout, 303 of them
      specs. The agent is told the spec is written, skips the component, and the
      gap surfaces later as an implementation with nothing behind it.

    * **a person** looking at the project in a browser has no checkout to name.
      `with_harness/2` already decided what to do about that — "adopting the
      wrong checkout's identity is worse than reading widely" — and refusing
      instead took the graph out of the UI entirely.

  So the default is loose and the agent path is strict by construction: it
  cannot reach here without a harness, because the plug that builds its scope
  puts one on. An unscoped load says so in the log, which is how a caller that
  should have named one gets found.

  ## Blending is a stand-in, not the answer

  The tempting fix is for the UI to pick a harness — the most recently seen
  one. It bounces: five checkouts reporting means the graph flips to whichever
  synced last, so the same page shows different requirements on consecutive
  renders with nothing the viewer did to cause it. Wrong-but-stable beats
  correct-but-flickering for a page someone is reading.

  The direction that resolves it is not picking better. It is that a web view
  should read the **default branch** over an API rather than any working copy:
  branch state is shared, stable, and canonical, where a checkout is transient
  and private. At that point the question "which harness is the UI showing"
  stops existing, and this clause can go.
  """
  @spec load(Scope.t()) :: {:ok, context()}
  def load(%Scope{active_working_copy_id: nil, active_project_id: project_id} = scope) do
    Logger.warning(
      "[Requirements] building a graph for project #{inspect(project_id)} with no working " <>
        "copy — every checkout's files are read together, so a file present in one and " <>
        "absent in another reads as present. Expected for the UI; an agent path here is a bug."
    )

    do_load(scope, nil)
  end

  def load(%Scope{active_working_copy_id: working_copy_id} = scope),
    do: do_load(scope, working_copy_id)

  defp do_load(%Scope{active_project_id: project_id} = scope, working_copy_id) do
    # 1. All components with deps and children preloaded
    components =
      Component
      |> where([c], c.project_id == ^project_id)
      |> preload([:dependencies, :child_components])
      |> Repo.all()

    # 2. This working copy's files, grouped by component and story
    #
    # Scoped to the harness, and it was not. Every checkout reports its own row
    # per path, so an unscoped load returned five copies of every file on this
    # project — ~18,650 rows for a tree of ~4,500 — and `has_role?/3` and
    # `has_valid_role?/2` answered from whichever the database happened to
    # return first.
    #
    # The cost is not the over-count. 308 `(component, role)` pairs were
    # satisfied here by files that exist only in *another* checkout, 303 of them
    # specs — so an agent in this working copy was told 303 components had specs
    # written, and skipped them. Over-satisfaction is the expensive direction:
    # work gets skipped rather than repeated, and the gap surfaces later as an
    # implementation with no spec behind it.
    #
    # One file currently disagrees across checkouts — a spec valid in two and
    # invalid in a third — which made `spec_valid` for that component depend on
    # row order. That is the same defect, just the loud instance of it.
    #
    # `acde83fd` scoped runs and problems and its own comment says it "missed
    # these two". This is a third site it missed, and it feeds every
    # `file_exists` and `file_valid` check in the graph.
    all_files =
      File
      |> where([f], f.project_id == ^project_id)
      |> scope_to_harness(working_copy_id)
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
    #
    # The assignment gate, and the reason story 895 exists. A copy is offered
    # its own stories and every unassigned one, and never another copy's:
    # *"if a harness is assigned stories, it should get its assigned stories
    # and all unassigned stories. Unassigned stories should surface to all
    # working copies."*
    #
    # Assignment narrows the backlog and never hides it. A project with no
    # assignments anywhere behaves exactly as it did before the column existed,
    # which is what makes the axis shippable empty — and it fails the safe way:
    # if unassigned work were invisible until claimed, a fresh project would
    # offer nobody anything.
    #
    # `nil` is the UI path, which blends every checkout deliberately (see the
    # clause above) and must not be narrowed to the unassigned pool — the page
    # is showing the project, not standing in a checkout.
    stories =
      Story
      |> where([s], s.project_id == ^project_id and s.ready_for_dev == true)
      |> assigned_here_or_unassigned(working_copy_id)
      |> Repo.all()

    story_ids = Enum.map(stories, & &1.id)

    {:ok,
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
       uat_deploy_by_story: uat_deploy_by_story(project_id),
       delegated_inputs: delegated_inputs(project_id)
     }}
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
  # `deploys` is the sixth and it arrived late, because it is the only one the
  # preloader was already loading — `uat_deploy_by_story` — while the
  # fingerprint hashed none of it. `deploy` asks `Deploys.uat_check/3`, which
  # reads that collection, so a deploy landing moved the graph and not the hash
  # and `cached_graph/1` served the pre-deploy projection as current. That is
  # the failure `16a24105` names: "a cached graph can tell an agent work is
  # finished that a deploy has just reopened".
  #
  # Loading a collection is not covering it. The other five were found by asking
  # what the checkers read; this one hid because the preloader's answer looked
  # like coverage.
  # `stories` is the seventh, and it is here for a reason worth stating: the
  # context already carries stories, and that is not the same set. `ctx.stories`
  # is filtered to `ready_for_dev == true` — only released stories project into
  # the graph — while `StoriesChecker` asks `Stories.project_has_stories?/1`,
  # which counts every one. A project whose only story is parked therefore read
  # as having none, and creating one did not move the hash. Onboarding is
  # exactly when that bites: the first story exists before anyone marks it
  # ready, and the graph is what the agent is following.
  @delegated_tables ~w(bdd_rules criteria questions personas issues deploys stories)

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
  # One clause, and no nil case.
  #
  # `ProblemRepository` falls back to the project's default harness when a scope
  # has none, and that fallback is part of why this took so long to find: it
  # makes a scope with no working copy look answerable, so nobody notices the
  # caller that forgot to set one. A requirement graph is a statement about a
  # checkout, and answering "no checkout" with the default one invents a tree
  # the caller was not asking about.
  # A nil harness reads every checkout's rows, which is what this did before and
  # what the warning above is for. Not an error: `with_harness/2` deliberately
  # leaves a request that names no harness unscoped — "adopting the wrong
  # checkout's identity is worse than reading widely" — and the browser has no
  # working copy to name. Refusing there took the requirement graph out of the
  # UI entirely and failed 86 spex.
  defp scope_to_harness(query, nil), do: query

  defp scope_to_harness(query, working_copy_id),
    do: where(query, [f], f.working_copy_id == ^working_copy_id)

  defp assigned_here_or_unassigned(query, nil), do: query

  defp assigned_here_or_unassigned(query, working_copy_id) do
    where(query, [s], is_nil(s.working_copy_id) or s.working_copy_id == ^working_copy_id)
  end

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

  # The UAT deploy per story. `Deploys.get/3` is a `Repo.one/1` on
  # `(project_id, story_id, environment)`, so there is at most one and a map
  # keyed by story is the same shape.
  #
  # Environment is pinned to "uat" here because `deploy` is the only node that
  # reads deploys and it asks about UAT only — prod promotion is the release
  # process's business.
  defp uat_deploy_by_story(project_id) do
    Deploy
    |> where([d], d.project_id == ^project_id and d.environment == "uat")
    |> Repo.all()
    |> Map.new(&{&1.story_id, &1})
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
