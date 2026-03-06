defmodule CodeMySpec.Requirements.AcceptedIssuesChecker do
  @moduledoc """
  Checks whether all medium+ accepted QA issues have been resolved.

  Queries the Issues context for accepted (unresolved) issues at medium+
  severity. Satisfied when none remain.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        _entity,
        _opts \\ []
      ) do
    unresolved =
      Issues.list_by_status(scope, :accepted)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    {satisfied, details} =
      case unresolved do
        [] ->
          {true, %{status: "No unresolved medium+ issues"}}

        issues ->
          {false,
           %{
             reason: "#{length(issues)} unresolved medium+ issue(s)",
             issues: Enum.map(issues, &%{title: &1.title, severity: &1.severity})
           }}
      end

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: satisfied,
      score: if(satisfied, do: 1.0, else: 0.0),
      checked_at: DateTime.utc_now(),
      details: details
    }
  end
end
