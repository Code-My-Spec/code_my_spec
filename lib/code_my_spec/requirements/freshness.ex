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
      {:story, story.id, story.ready_for_dev, story.working_copy_id, story.component_id},
      {:files, file_keys(Map.get(ctx.files_by_story, story.id, []))},
      {:rules, ids(Map.get(ctx.rules_by_story, story.id, []))},
      {:criteria, ids(Map.get(ctx.criteria_by_story, story.id, []))},
      {:questions, ids(Map.get(ctx.questions_by_story, story.id, []))},
      {:personas, ids(Map.get(ctx.personas_by_story, story.id, []))},
      {:qa, attempt_key(Map.get(ctx.qa_latest_by_story, story.id))},
      {:deploy, deploy_key(Map.get(ctx.uat_deploy_by_story, story.id))},
      {:running_copy, Map.get(ctx, :delegated_inputs, %{}) |> Map.get("working_copies")}
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
      {:component, component.id, component.type, component.module_name},
      {:files, file_keys(Map.get(ctx.files_by_component, component.id, []))},
      {:children, ids(Map.get(ctx.children_by_parent, component.id, []))},
      {:problems, Map.get(ctx.problems_by_component, component.id, %{})},
      {:analysis, Map.get(ctx, :analysis_fresh, %{})}
    ])
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
