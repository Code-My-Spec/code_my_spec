defmodule CodeMySpec.Requirements.Freshness do
  @moduledoc """
  What one entity's requirements were computed from, as a fingerprint.

  ## Why per entity rather than per project

  The graph carries a single fingerprint hashed over every input the project
  has, so any observation busts all of it and the next read rebuilds every node
  and edge. Measured on this project with a handful of agents, 2026-09-12: 348
  full computes in one log, median 2.6s, p90 5.9s, max 14.8s, 116 of them
  triggered by stop hooks, and edges alone 6489ms of a 10203ms compute.

  The cost is the grain, not the hash. A scenario added to one story says
  nothing about a story assigned to another checkout, and a project-wide
  fingerprint has no way to say so — so it discards both.

  ## Why per entity rather than per requirement

  Per requirement would be finer and is not obviously better. The requirements
  of one entity share almost all of their inputs: every story requirement reads
  that story's files, and most read its rules, criteria or attempts. Splitting
  them would hash the same values once per requirement to separate answers that
  move together anyway.

  Entity grain is also what the observable claim needs. "An observation
  recomputes what it touched and leaves the rest" — criterion 3424 — is about
  one story's requirements against another's.

  ## What goes in, and what deliberately does not

  In: everything a checker for that entity reads. For a story that is its own
  released and assigned state, its files, rules, criteria, questions, personas,
  latest QA attempt and UAT deploy — plus the running copy's state, because
  `code_on_running_copy` reads it and a story's answer genuinely changes when
  the running copy moves.

  Out: anything a checker does not read. `updated_at` on a row nothing consults
  would make every save look like a change, which is the failure this replaces
  rather than a cheaper version of it.

  ## Rows that are read are hashed by `updated_at`, not by named fields

  For a row a checker *does* read, the opposite holds, and criterion 5887 is
  what settled it. Naming fields means the fingerprint covers the fields this
  module happens to know about, and it was wrong twice in the same afternoon:
  `add_scenario` sets an existing criterion's `kind` and `rule_id`, which
  `BddRulesChecker` reads and this hashed by id alone; and the Three Amigos seal
  is `story.three_amigos_sealed`, which was not in the story's named fields at
  all. Both moved an answer without moving its fingerprint, so the stale row was
  kept and the graph went on offering work that had already been done.

  A missed input is silent and expensive — an agent holds a session that is
  already sealed — while an extra one costs a recompute. So every row a checker
  reads is keyed `{id, updated_at}`, the convention
  `Preloader.delegated_inputs/2` already uses, which covers every field read
  today and every field read later without this module tracking which.

  ## On hashing things we do not own

  For files the source key is a content hash, which is honest: we have the
  bytes. For a QA attempt or a git state it is an **id or a revision** — the
  attempt's id, the commit sha. Same idea, and it should not be called a hash
  of data we never read.
  """

  alias CodeMySpec.Requirements.Preloader

  @doc """
  One story's inputs, as a fingerprint.

  `nil` is never returned: a story with no files and no rules still has a
  fingerprint, and it is the fingerprint of having none. Returning `nil` there
  would read as "unknown" and force a recompute for the emptiest case.
  """
  @spec story(Preloader.context(), map()) :: String.t()
  def story(ctx, story) do
    hash([
      {:story, story.id, row_key(story), story.ready_for_dev, story.working_copy_id,
       story.component_id},
      {:files, file_keys(Map.get(ctx.files_by_story, story.id, []))},
      {:rules, row_keys(Map.get(ctx.rules_by_story, story.id, []))},
      {:criteria, row_keys(Map.get(ctx.criteria_by_story, story.id, []))},
      {:questions, row_keys(Map.get(ctx.questions_by_story, story.id, []))},
      {:personas, row_keys(Map.get(ctx.personas_by_story, story.id, []))},
      {:qa, attempt_key(Map.get(ctx.qa_latest_by_story, story.id))},
      {:deploy, deploy_key(Map.get(ctx.uat_deploy_by_story, story.id))},
      {:running_copy, Map.get(ctx, :delegated_inputs, %{}) |> Map.get("working_copies")},
      # `story_issues_resolved` delegates to `IssuesChecker.story_resolved?/3`,
      # and the preloader groups issues by nothing — they reach the context only
      # as project-wide stamps. Project-wide is what gets hashed, so an issue
      # accepted against one story reconsiders every story.
      #
      # Coarse on purpose, and the trade is not close. Issues are filed and
      # resolved by hand, a handful a day; files churn every time an agent
      # writes one. The alternative is leaving the input out, which is what
      # criterion 5887 already showed the cost of: the graph keeps offering work
      # that is finished, and nothing ever changes its mind. Grouping issues by
      # story in `Preloader` would narrow this, and until it does this is the
      # side to be wrong on.
      {:issues, Map.get(ctx, :delegated_inputs, %{}) |> Map.get("issues")}
    ])
  end

  @doc """
  One component's inputs, as a fingerprint.

  Children are included by id rather than by their own fingerprint: a context's
  requirements depend on *which* children it has — a child appearing adds nodes
  — and not on whether a child's own spec changed, which moves that child's
  requirements and not its parent's.
  """
  @spec component(Preloader.context(), map()) :: String.t()
  def component(ctx, component) do
    hash([
      {:component, component.id, row_key(component), component.type, component.module_name},
      {:files, file_keys(Map.get(ctx.files_by_component, component.id, []))},
      {:children, ids(Map.get(ctx.children_by_parent, component.id, []))},
      {:problems, Map.get(ctx.problems_by_component, component.id, %{})},
      {:analysis, Map.get(ctx, :analysis_fresh, %{})}
    ])
  end

  @doc """
  The shape the graph's edges describe, as a fingerprint.

  Nodes and edges are computed from different things, and conflating them is
  how a partial recompute goes quietly wrong. An edge comes from four places
  and none of them is a file's contents:

    * the template, chosen by `component.type` and filtered by the config
    * the component tree, via `parent_component_id`
    * cross-context dependencies, via `component.dependencies`
    * story attachment, via `story.component_id`

  So a spec file that declares a new dependency moves the component's inputs —
  which is caught — and moves the graph's shape, which is not, because the
  entity set is unchanged and the edges were kept. Membership is not shape.

  Deliberately blind to everything else. Whether a file is valid, whether QA
  passed, when a deploy ran: all of it moves nodes and none of it moves an
  edge, and including it would recompute 6489ms of edges to describe a shape
  that had not changed — which is the behaviour this exists to end.
  """
  @spec topology(Preloader.context(), map()) :: String.t()
  def topology(ctx, config) do
    components =
      ctx.components
      |> Enum.map(&{&1.id, &1.type, &1.parent_component_id, dependency_ids(&1)})
      |> Enum.sort()

    stories = ctx.stories |> Enum.map(&{&1.id, &1.component_id}) |> Enum.sort()

    hash([
      {:components, components},
      {:stories, stories},
      {:config, config_shape(config)}
    ])
  end

  # An unloaded association is not an empty one. Answering `[]` for it would
  # hash two different shapes the same way and reuse edges that describe
  # neither, so it is named for what it is and always looks changed.
  defp dependency_ids(component) do
    case component.dependencies do
      deps when is_list(deps) -> deps |> Enum.map(& &1.id) |> Enum.sort()
      _ -> :not_loaded
    end
  end

  # The config decides which requirement definitions exist, and an edge can
  # only connect definitions that do. Taken by the four keys the filters
  # actually read rather than by hashing the whole struct, which carries
  # timestamps and would make every config save look like a new shape.
  defp config_shape(config) do
    Enum.map(
      [:require_specs, :require_reviews, :require_unit_tests, :devops],
      &{&1, Map.get(config, &1)}
    )
  end

  @doc """
  The project's own inputs, as a fingerprint.

  Project requirements read counts rather than contents — whether any story
  exists, whether personas are complete — so this is deliberately coarse. It
  moves when a story or component appears, which is exactly when a project
  requirement can change.
  """
  @spec project(Preloader.context()) :: String.t()
  def project(ctx) do
    hash([
      {:stories, ids(ctx.stories)},
      {:components, ids(ctx.components)},
      {:files, file_keys(Map.get(ctx, :files_by_project, []))},
      {:delegated, Map.get(ctx, :delegated_inputs, %{})}
    ])
  end

  # A file's identity for this purpose is its path, its content hash and
  # whether it parsed — the three things a `file_exists` or `file_valid` check
  # reads. Sorted, because the order a query returned them in is not a change.
  defp file_keys(files) do
    files
    |> Enum.map(&{&1.path, Map.get(&1, :fingerprint), Map.get(&1, :valid)})
    |> Enum.sort()
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()

  # `{id, updated_at}`, because these rows are edited in place and the checkers
  # read their contents rather than their existence.
  #
  # Identity alone was wrong and criterion 5887 is what said so. `add_scenario`
  # sets an existing criterion's `kind` and `rule_id`; `BddRulesChecker` reads
  # exactly those two — `Enum.filter(criteria, &(not is_nil(&1.kind)))`, then
  # `Enum.group_by(scenarios, & &1.rule_id)` — so a story went from "a rule with
  # no scenario" to "covered" with its set of criterion ids unchanged. The
  # fingerprint matched, the row was kept, and the graph went on offering a
  # Three Amigos session that had already been held. A question being answered
  # is the same shape: `status` moves from `:open`, the id does not.
  #
  # `updated_at` rather than the fields themselves, which is the convention
  # `Preloader.delegated_inputs/2` already uses for the same reason: it covers
  # every field a checker reads today and every one it starts reading later,
  # without this module having to track what that is. The objection in the
  # moduledoc — that a timestamp makes every save look like a change — is about
  # rows nothing consults. These are consulted.
  defp row_keys(rows), do: rows |> Enum.map(&row_key/1) |> Enum.sort()

  # The same question asked of one row, including the entity's own.
  #
  # Criterion 5887 found the second half of this: `three_amigos_complete`
  # delegates to `BddRulesChecker.sealed?/2`, which reads
  # `story.three_amigos_sealed` — a field on the story itself, flipped by
  # `ThreeAmigos.evaluate/2` through a normal changeset update. The fields named
  # beside this one are the fields *this module* happened to know about, and the
  # seal was not among them, so a story went from unsealed to sealed with its
  # fingerprint unchanged and the graph kept offering a conversation that had
  # already been held.
  #
  # Enumerating fields means being wrong again the next time a checker reads one
  # nobody added here — silently, and in the direction that costs an agent a
  # session rather than costing a recompute. The row's own `updated_at` is the
  # question actually being asked: did this row change.
  defp row_key(row), do: {row.id, Map.get(row, :updated_at)}

  # The attempt's identity, not its contents. A QA attempt is immutable once
  # inserted, so its id is a complete answer to "is this the same attempt" —
  # and its invalidations are what make a pass stop counting, so they are here
  # too.
  defp attempt_key(nil), do: nil

  defp attempt_key(attempt) do
    {attempt.id, attempt.status, length(Map.get(attempt, :invalidations, []) || [])}
  end

  defp deploy_key(nil), do: nil
  defp deploy_key(deploy), do: {deploy.id, Map.get(deploy, :status)}

  defp hash(terms) do
    terms
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end
end
