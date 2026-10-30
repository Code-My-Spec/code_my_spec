defmodule CodeMySpec.Requirements.Preloader do
  @moduledoc """
  Bulk-loads all data needed for requirement computation in minimal queries.

  Returns a context map that RequirementCalculator and RequirementGraph
  use instead of per-component queries. Eliminates N+1.
  """

  import Ecto.Query

  require Logger

  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Configurations
  alias CodeMySpec.Deploys.Deploy
  alias CodeMySpec.Files.File
  alias CodeMySpec.Issues
  alias CodeMySpec.Personas.{Persona, PersonaStory}
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.DevopsSetupChecker
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Stories.AcceptanceCriteria.Criterion
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type context :: %{
          files_by_component: %{Ecto.UUID.t() => [File.t()]},
          files_by_story: %{integer() => [File.t()]},
          files_by_project: [File.t()],
          files_by_path: %{String.t() => File.t()},
          issues_by_story: %{integer() => [{integer(), NaiveDateTime.t()}]},
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
          delegated_inputs: %{String.t() => [{term(), NaiveDateTime.t()}]},
          setup_missing: %{String.t() => [String.t()] | :not_started}
        }

  @doc """
  Load all data for the project's whole computation at one vantage.

  A scope naming a checkout reads that checkout's files and its own plus
  unassigned stories. A scope naming none reads the project's reading copy's
  files (`files_vantage/1`; every checkout's when the project has none) and
  every ready story: files must be one tree that existed, but a person looking
  at the project is asking about all of its stories.
  See knowledge/requirements_graph/checkers, "Preloading".

  `opts[:shared]` supplies a `shared/1` already loaded for this drain.
  """
  @spec load(Scope.t()) :: {:ok, context()}
  def load(scope, opts \\ [])

  def load(%Scope{active_working_copy_id: nil} = scope, opts) do
    do_load(scope, nil, files_vantage(scope), opts)
  end

  def load(%Scope{active_working_copy_id: working_copy_id} = scope, opts),
    do: do_load(scope, working_copy_id, working_copy_id, opts)

  defp do_load(
         %Scope{active_project_id: project_id} = scope,
         working_copy_id,
         files_copy_id,
         opts
       ) do
    {shared_us, shared} =
      :timer.tc(fn -> Keyword.get_lazy(opts, :shared, fn -> shared(project_id) end) end)

    %{components: components} = shared

    # One checkout's files: every checkout files its own row per path, and a
    # file in another worktree must never satisfy a requirement here.
    {files_us, all_files} =
      :timer.tc(fn ->
        File
        |> where([f], f.project_id == ^project_id)
        |> scope_to_harness(files_copy_id)
        |> Repo.all()
      end)

    files_by_component =
      all_files
      |> Enum.filter(& &1.component_id)
      |> Enum.group_by(& &1.component_id)

    files_by_story =
      all_files
      |> Enum.filter(& &1.story_id)
      |> Enum.group_by(& &1.story_id)

    # Stories: only `ready_for_dev` ones project (a filter, not a node — an
    # agent would just satisfy a node); a checkout gets its own and the
    # unassigned ones; `nil` gets every ready story.
    # See knowledge/requirements_graph/checkers, "Preloading".
    {stories_us, stories} = :timer.tc(fn -> project_stories(project_id, working_copy_id) end)

    story_ids = Enum.map(stories, & &1.id)

    {rest_us, rest} =
      :timer.tc(fn ->
        %{
          criteria_by_story: criteria_by_story(story_ids),
          personas_by_story: personas_by_story(story_ids),
          qa_latest_by_story: qa_latest_by_story(story_ids),
          qa_submission_snapshots:
            Issues.story_submission_snapshots(
              scope,
              story_ids,
              Configurations.fix_issues_min_severity(scope)
            ),
          delegated_inputs: delegated_inputs(project_id, working_copy_id),
          # Once per load rather than once per story's `deploy`, and in the
          # context so `Freshness.story/2` sees setup completing.
          setup_missing: %{"uat" => DevopsSetupChecker.missing(scope, "uat")}
        }
      end)

    log_load_cost(project_id, working_copy_id, length(all_files), %{
      shared: shared_us,
      files: files_us,
      stories: stories_us,
      rest: rest_us
    })

    {:ok,
     %{
       files_by_component: files_by_component,
       files_by_story: files_by_story,
       files_by_project: all_files,
       files_by_path: Map.new(all_files, &{&1.path, &1}),
       issues_by_story: shared.issues_by_story,
       story_issues: shared.story_issues,
       components: components,
       components_by_id: Map.new(components, &{&1.id, &1}),
       children_by_parent: Enum.group_by(components, & &1.parent_component_id),
       stories: stories,
       rules_by_story: shared.rules_by_story,
       questions_by_story: shared.questions_by_story,
       criteria_by_story: rest.criteria_by_story,
       personas_by_story: rest.personas_by_story,
       qa_latest_by_story: rest.qa_latest_by_story,
       qa_submission_snapshots: rest.qa_submission_snapshots,
       uat_deploy_by_story: shared.uat_deploy_by_story,
       delegated_inputs: rest.delegated_inputs,
       setup_missing: rest.setup_missing
     }}
  end

  # Stamps (`{id, updated_at}`) of every table the `:delegate` checkers read,
  # hashed into each fingerprint; the checkers still query for themselves.
  # Timestamps are safe here because none of these are bulk-upserted. `stories`
  # is every story, not `ctx.stories` (ready ones only): `StoriesChecker` counts
  # parked stories too. See knowledge/requirements_graph/checkers, "Fingerprints".
  @delegated_tables ~w(bdd_rules criteria questions personas issues deploys stories)

  @doc """
  Whose files a computation reads: the scope's own checkout, or the project's
  reading copy when it names none.

  `files_vantage/1` answers the reading copy for any scope and never looks at
  the working copy, so narrow loaders must call this, not it.
  `Profiles.scope_files_to_copy/2` follows the same rule.
  """
  @spec files_copy(Scope.t()) :: Ecto.UUID.t() | nil
  def files_copy(%Scope{active_working_copy_id: copy}) when is_binary(copy), do: copy
  def files_copy(%Scope{} = scope), do: files_vantage(scope)

  @doc """
  Which checkout's files a reader that named none is shown.

  Public so `Requirements.Profiles` picks the same checkout for the same
  requirements. The rule lives in `WorkingCopies.reading_copy_id/1` (the
  project's default copy, else its main one), where `Files` can follow it too.
  """
  @spec files_vantage(Scope.t()) :: Ecto.UUID.t() | nil
  def files_vantage(%Scope{} = scope), do: CodeMySpec.WorkingCopies.reading_copy_id(scope)

  @doc """
  The project's vantage-invariant half, loaded once and shared across the
  checkouts a drain settles.

  Every checkout shares these rows exactly (components with dependencies and
  children, rules, questions, issue stamps, deploys); only files differ per
  vantage. `load/2` builds it when no caller supplies one. Emits
  `DrainCost.project_preload/0`, so a drain's count of these loads is
  checkable.
  """
  @spec shared(Ecto.UUID.t()) :: map()
  def shared(project_id) do
    :telemetry.execute(DrainCost.project_preload(), %{count: 1}, %{project_id: project_id})

    %{
      components: project_components(project_id),
      issues_by_story: issue_stamps_by_story(project_id),
      story_issues: project_story_issues(project_id),
      rules_by_story: rules_by_story(project_id),
      questions_by_story: questions_by_story(project_id),
      uat_deploy_by_story: uat_deploy_by_story(project_id)
    }
  end

  # Announced through `shared/1`, so the count is of the shared load, not of
  # this query (which `topology_context/1` also runs).
  defp project_components(project_id) do
    Component
    |> where([c], c.project_id == ^project_id)
    |> preload([:dependencies, :child_components])
    |> Repo.all()
  end

  # What a preload cost, split by phase, with the file row count the times only
  # mean something beside.
  defp log_load_cost(project_id, working_copy_id, file_count, parts) do
    ms = fn us -> div(us, 1000) end
    total = parts |> Map.values() |> Enum.sum() |> ms.()

    Logger.info(
      "[Preloader] loaded in #{total}ms — " <>
        "shared #{ms.(parts.shared)}ms, files #{ms.(parts.files)}ms (#{file_count} rows), " <>
        "stories #{ms.(parts.stories)}ms, " <>
        "rest #{ms.(parts.rest)}ms; " <>
        "project=#{project_id} copy=#{inspect(working_copy_id)}"
    )
  end

  @doc """
  The shape inputs and nothing else: components with their dependencies and
  children, and this vantage's stories.

  Enough for `Freshness.topology/2` and `Edges.generate/3`, and for rehydrating
  a stored row (`components_by_id`, `stories`), without a full `load/2`. Not
  enough for any verdict.
  """
  @spec topology_context(Scope.t()) :: map()
  def topology_context(%Scope{active_project_id: project_id} = scope) do
    components = project_components(project_id)

    %{
      components: components,
      components_by_id: Map.new(components, &{&1.id, &1}),
      children_by_parent: Enum.group_by(components, & &1.parent_component_id),
      story_issues: project_story_issues(project_id),
      stories: project_stories(project_id, scope.active_working_copy_id)
    }
  end

  @doc """
  What a read of stored rows needs, and nothing a checker needs.

  `topology_context/1` plus each story's questions, for story execution. A read
  never loads `load/2`'s context: every file row and checker input on the
  checkout, a second a call on a large project. Keys it does not load stay
  absent. See knowledge/requirements_graph, "The read path".
  """
  @spec read_context(Scope.t()) :: map()
  def read_context(%Scope{active_project_id: project_id} = scope) do
    scope
    |> topology_context()
    |> Map.put(:questions_by_story, questions_by_story(project_id))
  end

  defp project_story_issues(project_id) do
    Repo.all(
      from(i in CodeMySpec.Issues.Issue,
        where: i.project_id == ^project_id and not is_nil(i.story_id)
      )
    )
  end

  defp project_stories(project_id, working_copy_id) do
    Story
    |> where([s], s.project_id == ^project_id and s.ready_for_dev == true)
    |> assigned_here_or_unassigned(working_copy_id)
    |> Repo.all()
  end

  @doc """
  The ready stories reserved for a checkout other than this scope's.

  For a role that reads every story wherever it is placed
  (`RoleProfile.story_vantage/1` is `:project` — product).
  `load/2` leaves these out on purpose: a copy is offered its own stories and
  the unassigned ones. Their verdicts live at their placement copy's vantage,
  which `CopyGraph.placed/3` reads. Empty for a scope naming no checkout, which
  already reads every story.
  """
  @spec placed_elsewhere(Scope.t()) :: [Story.t()]
  def placed_elsewhere(%Scope{active_working_copy_id: nil}), do: []

  def placed_elsewhere(%Scope{active_project_id: project_id, active_working_copy_id: copy_id}) do
    Story
    |> where([s], s.project_id == ^project_id and s.ready_for_dev == true)
    |> where([s], not is_nil(s.working_copy_id) and s.working_copy_id != ^copy_id)
    |> Repo.all()
  end

  defp scope_to_harness(query, nil), do: query

  defp scope_to_harness(query, working_copy_id),
    do: where(query, [f], f.working_copy_id == ^working_copy_id)

  defp assigned_here_or_unassigned(query, nil), do: query

  defp assigned_here_or_unassigned(query, working_copy_id) do
    where(query, [s], is_nil(s.working_copy_id) or s.working_copy_id == ^working_copy_id)
  end

  @doc """
  One story's context, for a consumer that is only going to compute that story.

  The story, its files, its issue submissions and latest QA attempt. For one
  story, the delegates' own per-story queries are cheaper than `load/1`'s
  project-wide batch, so they are left to query for themselves.
  `files_by_path` is not carried: the story graph has no `:path_exists`.

  `skip_fingerprints` is set and `delegated_inputs` absent: a fingerprint from
  a narrow context would be plausible but not the one a whole load produces, so
  the row's `inputs_fingerprint` is `nil`.

  Answers with an empty context when the story is not in this vantage's scope
  (parked, or assigned to another checkout), so the consumer writes no rows.
  """
  @spec load_story(Scope.t(), integer()) :: {:ok, context()}
  def load_story(%Scope{active_project_id: project_id} = scope, story_id)
      when is_binary(project_id) do
    story =
      Story
      |> where([s], s.id == ^story_id and s.project_id == ^project_id and s.ready_for_dev == true)
      |> assigned_here_or_unassigned(scope.active_working_copy_id)
      |> Repo.one()

    {:ok, story_context(scope, story)}
  end

  defp story_context(_scope, nil), do: narrow_context([])

  defp story_context(scope, story) do
    files =
      File
      |> where([f], f.story_id == ^story.id)
      |> scope_to_harness(files_copy(scope))
      |> Repo.all()

    [story]
    |> narrow_context()
    |> Map.put(:files_by_story, %{story.id => files})
    |> Map.put(:story_issues, Issues.list_story_submissions(scope, story.id))
    |> Map.put(:qa_latest_by_story, qa_latest_by_story([story.id]))
    |> Map.put(
      :qa_submission_snapshots,
      Issues.story_submission_snapshots(
        scope,
        [story.id],
        Configurations.fix_issues_min_severity(scope)
      )
    )
  end

  # Only the keys a narrow load fills. Checkers read `ctx[:key]` and query the
  # database when it is absent; an empty collection is an answer ("no QA
  # attempt") they believe. See knowledge/requirements_graph/checkers,
  # "Preloading".
  defp narrow_context(stories) do
    %{
      stories: stories,
      components: [],
      files_by_story: %{},
      skip_fingerprints: true
    }
  end

  @doc """
  The project's own requirements need the checkout's files and nothing else.

  The `:path_exists` ones resolve through `files_by_path`,
  `qa_integration_plan` reads `files_by_project`, and the rest query for
  themselves. One file query; every other key is absent, so a checker reading
  `ctx[:key]` falls through to the database.
  """
  @spec load_project(Scope.t()) :: {:ok, context()}
  def load_project(%Scope{active_project_id: project_id} = scope)
      when is_binary(project_id) do
    files =
      File
      |> where([f], f.project_id == ^project_id)
      |> scope_to_harness(files_copy(scope))
      |> Repo.all()

    ctx =
      []
      |> narrow_context()
      |> Map.merge(%{
        files_by_project: files,
        files_by_path: Map.new(files, &{&1.path, &1})
      })

    {:ok, ctx}
  end

  @doc """
  One component's template family, with the ancestor context needed to preserve
  whether each component is a top-level template owner or a child emitted by
  its parent. A child nested below a context cannot be computed alone: omitting
  the context makes `component_families/1` promote it to top-level and changes
  its definition metadata.

  No problems are loaded: no component requirement reads them.
  """
  @spec load_component_family(Scope.t(), Ecto.UUID.t()) :: {:ok, context()}
  def load_component_family(%Scope{active_project_id: project_id} = scope, id)
      when is_binary(project_id) do
    lineage = component_context_lineage(project_id, id)
    ids = Enum.uniq([id | lineage])
    {:ok, family_context(scope, ids)}
  end

  defp family_context(%Scope{active_project_id: project_id} = scope, ids) do
    family =
      Component
      |> where([c], c.project_id == ^project_id)
      |> where([c], c.id in ^ids or c.parent_component_id in ^ids)
      |> preload([:dependencies, :child_components])
      |> Repo.all()

    ids = Enum.map(family, & &1.id)

    files =
      File
      |> where([f], f.component_id in ^ids)
      |> scope_to_harness(files_copy(scope))
      |> Repo.all()

    []
    |> narrow_context()
    |> Map.merge(%{
      components: family,
      components_by_id: Map.new(family, &{&1.id, &1}),
      children_by_parent: Enum.group_by(family, & &1.parent_component_id),
      files_by_component: Enum.group_by(files, & &1.component_id)
    })
  end

  # Keep walking only through ancestors that own child templates. A component
  # below a non-container parent is top-level in the full graph, so that parent
  # is irrelevant to its template. Context ancestors are included so the same
  # component_families/1 classification holds at every level of a nested path.
  defp component_context_lineage(project_id, component_id, seen \\ MapSet.new()) do
    if MapSet.member?(seen, component_id) do
      []
    else
      seen = MapSet.put(seen, component_id)

      component_context_lineage_step(project_id, component_id, seen)
    end
  end

  defp component_context_lineage_step(project_id, component_id, seen) do
    parent_id =
      Repo.one(
        from(c in Component,
          where: c.id == ^component_id and c.project_id == ^project_id,
          select: c.parent_component_id
        )
      )

    with id when not is_nil(id) <- parent_id,
         type when is_binary(type) <-
           Repo.one(
             from(c in Component,
               where: c.id == ^id and c.project_id == ^project_id,
               select: c.type
             )
           ),
         true <- RequirementsRegistry.has_children?(type) do
      [id | component_context_lineage(project_id, id, seen)]
    else
      _ -> []
    end
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

  # The newest QA attempt per story, invalidations preloaded — what
  # `QaAttempts.complete?/2` fetches one story at a time. The whole attempt, so
  # pass/fail stays the Qa context's judgement. Ordered by the database on
  # `complete?/2`'s keys; `group_by` keeps order, so each head is the newest
  # (`DISTINCT ON` would not port to SQLite).
  defp qa_latest_by_story(story_ids) do
    QaAttempt
    |> where([a], a.story_id in ^story_ids and not a.stale)
    |> order_by([a], desc_nulls_last: a.review_started_at, desc: a.submitted_at, desc: a.id)
    |> preload([:invalidations])
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
    |> Map.new(fn {story_id, [latest | _]} -> {story_id, latest} end)
  end

  # The UAT deploy per story (at most one per story and environment). Only
  # `deploy` reads deploys, and only UAT.
  defp uat_deploy_by_story(project_id) do
    Deploy
    |> where([d], d.project_id == ^project_id and d.environment == "uat")
    |> Repo.all()
    |> Map.new(&{&1.story_id, &1})
  end

  defp delegated_inputs(project_id, working_copy_id) do
    @delegated_tables
    |> Map.new(fn table -> {table, stamps(table, project_id)} end)
    |> Map.put("qa_attempts", qa_attempt_stamps(project_id))
    |> Map.put("persona_stories", persona_story_links(project_id))
    |> Map.put("working_copies", working_copy_gate_inputs(project_id, working_copy_id))
  end

  # The link, not the persona: `personas_complete` and `three_amigos_complete`
  # gate on it, and covering `personas` says nothing about it. Ids, since the
  # question is only which stories have a persona.
  defp persona_story_links(project_id) do
    Repo.all(
      from(ps in "persona_stories",
        join: s in "stories",
        on: s.id == ps.story_id,
        where: s.project_id == type(^project_id, :binary_id),
        select: {ps.story_id, ps.persona_id},
        order_by: [ps.story_id, ps.persona_id]
      )
    )
  end

  # Only the columns the running-copy gate reads, from the two copies it reads:
  # the main copy's `preview_status`/`preview_url` and whether the asking copy
  # exists. Never `stamps/2` or volatile columns (`last_seen_at`,
  # `preview_checked_at`): this map is hashed into every story's fingerprint.
  # With no checkout, only whether a copy is designated.
  # See knowledge/requirements_graph/checkers, "Fingerprints".
  defp working_copy_gate_inputs(project_id, nil), do: designated_copy(project_id)

  defp working_copy_gate_inputs(project_id, working_copy_id),
    do: running_copy_inputs(project_id) ++ asking_copy_inputs(project_id, working_copy_id)

  defp designated_copy(project_id) do
    Repo.all(
      from(c in "working_copies",
        where: c.project_id == type(^project_id, :binary_id) and c.main,
        select: {"designated", c.id}
      )
    )
  end

  defp running_copy_inputs(project_id) do
    Repo.all(
      from(c in "working_copies",
        left_join: i in "app_instances",
        on: i.working_copy_id == c.id and i.default == true,
        where: c.project_id == type(^project_id, :binary_id) and c.main,
        select: {"running", c.id, i.preview_status, i.preview_url}
      )
    )
  end

  # Only whether the asking copy is on file; none of its columns decides a
  # verdict.
  defp asking_copy_inputs(project_id, working_copy_id) do
    Repo.all(
      from(c in "working_copies",
        where:
          c.project_id == type(^project_id, :binary_id) and
            c.id == type(^working_copy_id, :binary_id),
        select: {"here", c.id}
      )
    )
  end

  # `qa_attempts` hangs off stories, not the project, so it cannot use `stamps/2`.
  # Read by `Qa.complete_check`, which backs `qa_complete`.
  #
  # Invalidations too: one writes its own row and leaves the attempt unchanged,
  # so attempt stamps alone do not move when a pass is thrown out.
  defp qa_attempt_stamps(project_id) do
    Repo.all(
      from(a in "qa_attempts",
        join: s in "stories",
        on: s.id == a.story_id,
        where: s.project_id == type(^project_id, :binary_id),
        select: {a.id, a.updated_at},
        order_by: a.id
      )
    ) ++ qa_invalidation_stamps(project_id)
  end

  defp qa_invalidation_stamps(project_id) do
    Repo.all(
      from(i in "qa_invalidations",
        join: a in "qa_attempts",
        on: a.id == i.qa_attempt_id,
        join: s in "stories",
        on: s.id == a.story_id,
        where: s.project_id == type(^project_id, :binary_id),
        select: {i.id, i.qa_attempt_id},
        order_by: i.id
      )
    )
  end

  defp stamps(table, project_id) do
    Repo.all(
      from(r in table,
        where: r.project_id == type(^project_id, :binary_id),
        select: {r.id, r.updated_at},
        order_by: r.id
      )
    )
  end

  # Story-local stamps cover triage and inherited submission state. Moving an
  # issue invalidates both its old and new story without dirtying every story.
  defp issue_stamps_by_story(project_id) do
    Repo.all(
      from(i in "issues",
        where: i.project_id == type(^project_id, :binary_id) and not is_nil(i.story_id),
        select: {i.story_id, i.id, i.updated_at},
        order_by: i.id
      )
    )
    |> Enum.group_by(
      fn {story_id, _id, _at} -> story_id end,
      fn {_story_id, id, at} -> {id, at} end
    )
  end
end
