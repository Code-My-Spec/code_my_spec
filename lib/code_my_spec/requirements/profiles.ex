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
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Issues
  alias CodeMySpec.Problems
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type name :: :issues | :specs
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
