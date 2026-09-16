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

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Users.Scope

  @type name :: :issues
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
end
