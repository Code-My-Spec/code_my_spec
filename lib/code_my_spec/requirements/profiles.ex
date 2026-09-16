defmodule CodeMySpec.Requirements.Profiles do
  @moduledoc """
  One set-based read of a domain slice, shared by every requirement computed
  from it.

  ## Why profiles and not queries-per-handler

  Thirty distinct requirement names, and they do not read thirty different
  things. Five `file_exists` names all read *which roles a component has files
  for*. Three `file_valid` names read *whether those files parsed*. Three issue
  names read *which issues are open and where*. The expensive part is the read,
  the read is shared, and the per-requirement part is a map lookup.

  So a profile is loaded once per drain and every requirement fed by it is
  settled from memory. Adding a requirement is a lookup function; adding a
  profile is a query. Neither is a new query per requirement, which is what a
  handler-per-requirement design quietly becomes.

  ## Set-based, always

  A profile answers for the whole project, not for one entity. That is what lets
  a handler settle `story_issues_resolved` for every story with one query and
  two writes rather than one query per story — and it is why the population size
  stops mattering.

  ## Each requirement keeps the filters it already had

  A profile calls the same functions the checkers call. `issues_triaged` and
  `issues_resolved` read through `list_by_status_and_min_severity/3`, which
  applies `exclude_framework_unless_vendor/2` and
  `exclude_other_copies_stories/2`; `story_issues_resolved` reads through the
  story variant, which applies neither. They are three reads in one profile
  rather than one read serving three, precisely because collapsing them would
  change what two of the requirements mean.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Analysis
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Configurations
  alias CodeMySpec.Deploys.Deploy
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Issues
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type name :: :issues | :specs | :files | :problems | :links
  @type t :: map()

  @doc """
  Load one profile. Called at most once per drain, however many requirements
  read it.
  """
  @spec load(Scope.t(), name()) :: t()
  def load(%Scope{} = scope, :issues) do
    threshold = Configurations.fix_issues_min_severity(scope)

    %{
      threshold: threshold,
      incoming: Issues.list_by_status_and_min_severity(scope, :incoming, threshold),
      accepted: Issues.list_by_status_and_min_severity(scope, :accepted, threshold),
      unresolved_by_story: Issues.unresolved_by_story(scope, threshold)
    }
  end

  # Every `file_exists` and `file_valid` requirement in the graph — 76 of the
  # 110 definitions — from one file read plus the two entity lists.
  #
  # Eight names, and each maps to exactly one role and one kind across all
  # fifteen graphs: `spec_file`/`spec_valid` to `:spec`, `test_file`/
  # `test_spec_alignment` to `:test`, `review_file`/`review_valid` to `:review`,
  # `implementation_file` to `:implementation`, `bdd_specs_exist` to
  # `:bdd_spec`. So they are a table and two shapes rather than eight handlers.
  #
  # The entity lists are here for the *unsatisfied* side. A component missing a
  # spec needs `expected_path` in its details — `RequirementsFormatter` renders
  # it, and it is the one thing telling an agent where to write the file — and
  # that is per component, so those entities have to be enumerated rather than
  # swept.
  #
  # Files are scoped to the checkout for the reason `Preloader.load/1` gives at
  # length: blended, a file present in another worktree reads as present here,
  # which it measured at 303 components whose specs an agent was told existed
  # and skipped.
  def load(%Scope{active_project_id: project_id} = scope, :files) do
    files =
      Repo.all(
        from(f in FileRecord,
          where: f.project_id == ^project_id,
          # Whole rows, not a chosen subset.
          #
          # Selecting fields looked tidy and silently changed a verdict:
          # `QaIntegrationPlan.check_index/1` reads `size` to decide whether the
          # integrations index is empty, which this did not carry, so every
          # index read as empty and `qa_integration_plan` came back invalid
          # against a project where it is fine. Caught by the diff.
          #
          # A profile feeds checkers written against `Files.File`, and which
          # fields each of them reads is not this module's to know.
          select: f
        )
        |> scope_files_to_copy(scope)
      )

    %{
      project: scope.active_project,
      components: Repo.all(from(c in Component, where: c.project_id == ^project_id)),
      story_ids: Repo.all(from(s in Story, where: s.project_id == ^project_id, select: s.id)),
      by_component_role: index_by(files, :component_id),
      by_story_role: index_by(files, :story_id),
      # For the six project `path_exists` requirements, which ask about named
      # paths and one prefix rather than about an owner's roles. Same read.
      by_path: Map.new(files, &{&1.path, &1}),
      all: files
    }
  end

  # Problem counts per component and source, which is what `problem_verdict/5`
  # reads and all `tests_passing` asks for.
  #
  # Aggregated in the database for the reason `Preloader.do_load/3` gives: the
  # alternative is loading every problem row, messages included, to count them.
  def load(%Scope{active_project_id: project_id}, :problems) do
    counts =
      Repo.all(
        from(p in Problem,
          where: p.project_id == ^project_id and not is_nil(p.component_id),
          group_by: [p.component_id, p.source],
          select: {p.component_id, p.source, count(p.id)}
        )
      )

    %{
      by_component_source:
        Enum.reduce(counts, %{}, fn {component_id, source, n}, acc ->
          Map.update(acc, component_id, %{source => n}, &Map.put(&1, source, n))
        end)
    }
  end

  # Everything `bdd_specs_passing` reads, for every story, in three reads.
  #
  # The requirement has three outcomes and `SpecsPassingChecker.passing?/3`
  # takes them in order: a story that is not `specs_ready` fails outright; one
  # that is, with no fresh spex run, passes because there is nothing to
  # re-check against; one that is, with a fresh run, passes only if none of its
  # own spec files are failing.
  #
  # `spex_fresh?` comes from `Analysis.Freshness` when the projection knows and
  # the comparison when it does not — the one place this profile is cheap by
  # design rather than by accident, since the alternative is hashing the
  # checkout's whole file table to answer one boolean.
  def load(%Scope{active_project_id: project_id} = scope, :specs) do
    %{
      spex_fresh?: spex_fresh?(scope),
      specs_ready: specs_ready_by_story(project_id),
      failing_by_story: failing_specs_by_story(scope, project_id)
    }
  end

  # What each story points at: the component it names, and its UAT deploy.
  #
  # Two requirements, one read each, and both are about a reference rather than
  # about the story — `component_linked` asks whether the named component
  # actually exists, `deploy` whether the recorded deploy passed its health
  # check. Neither is answerable from the story row alone, which is why they are
  # a profile rather than a field lookup.
  def load(%Scope{active_project_id: project_id}, :links) do
    %{
      component_id_by_story:
        Repo.all(
          from(s in Story,
            where: s.project_id == ^project_id,
            select: {s.id, s.component_id}
          )
        )
        |> Map.new(),
      component_ids:
        Repo.all(from(c in Component, where: c.project_id == ^project_id, select: c.id))
        |> MapSet.new(),
      # Pinned to UAT because the `deploy` requirement's config is, and
      # `Preloader.uat_deploy_by_story/1` reads it the same way: prod promotion
      # is the release process's business, not this node's.
      uat_deploy_by_story:
        Repo.all(
          from(d in Deploy,
            where: d.project_id == ^project_id and d.environment == "uat"
          )
        )
        |> Map.new(&{&1.story_id, &1})
    }
  end

  # `{owner_id, role} => file`, keeping the first of any duplicates — the same
  # `Enum.find/2` semantics `has_role?/3` and `has_valid_role?/2` use when a
  # checkout somehow holds two rows for one role.
  defp index_by(files, owner_key) do
    files
    |> Enum.filter(&Map.get(&1, owner_key))
    |> Enum.reduce(%{}, fn file, acc ->
      Map.put_new(acc, {Map.get(file, owner_key), file.role}, file)
    end)
  end

  defp scope_files_to_copy(query, %Scope{active_working_copy_id: copy}) when is_binary(copy),
    do: from(f in query, where: f.working_copy_id == type(^copy, Ecto.UUID))

  defp scope_files_to_copy(query, %Scope{}), do: query

  defp spex_fresh?(%Scope{active_working_copy_id: copy} = scope) do
    case Analysis.Freshness.known(copy, "spex") do
      nil -> Analysis.fresh?(scope, "spex")
      known -> known
    end
  end

  defp specs_ready_by_story(project_id) do
    Repo.all(
      from(s in Story,
        where: s.project_id == ^project_id,
        select: {s.id, s.specs_ready}
      )
    )
    |> Map.new()
  end

  # This story's own spec files, and which of them the current spex run is
  # failing. Grouped rather than asked per story, so a project with a hundred
  # stories costs the same two reads as one with three.
  defp failing_specs_by_story(scope, project_id) do
    paths_by_story =
      Repo.all(
        from(f in FileRecord,
          where: f.project_id == ^project_id and f.role == :bdd_spec and not is_nil(f.story_id),
          select: {f.story_id, f.path}
        )
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    failing =
      scope
      |> Problems.list_project_problems(source: "spex", severity: :error)
      |> Enum.group_by(& &1.file_path)

    Map.new(paths_by_story, fn {story_id, paths} ->
      {story_id, paths |> Enum.flat_map(&Map.get(failing, &1, [])) |> Enum.uniq()}
    end)
  end
end
