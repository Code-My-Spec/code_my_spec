defmodule CodeMySpec.Requirements.IncomingIssuesChecker do
  @moduledoc """
  Checks whether incoming QA issues at medium+ severity have been triaged.

  Queries the Issues context for incoming issues. Satisfied when none at
  medium, high, or critical severity remain. Low and info issues are
  ignored — they don't block the workflow.
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
    triageable =
      Issues.list_by_status(scope, :incoming)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    {satisfied, details} =
      case triageable do
        [] ->
          {true, %{status: "No untriaged issues at medium+ severity"}}

        issues ->
          scope_counts =
            issues
            |> Enum.map(& &1.scope)
            |> Enum.frequencies()

          {false,
           %{
             reason: "#{length(issues)} untriaged issue(s) at medium+ severity",
             issues: Enum.map(issues, &%{title: &1.title, severity: &1.severity}),
             scopes: scope_counts
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
