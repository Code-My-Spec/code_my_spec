defmodule CodeMySpec.Requirements.IssuesChecker do
  @moduledoc """
  Delegate checks for issue-related requirements.

  Used by RequirementCalculator via `:delegate` check_type.
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue

  @doc "Check that no incoming issues at medium+ severity remain untriaged."
  @spec triaged?(term(), term()) :: {boolean(), map()}
  def triaged?(scope, _entity) do
    triageable =
      Issues.list_by_status(scope, :incoming)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if triageable == [],
      do: {true, %{status: "No untriaged issues at medium+ severity"}},
      else: {false, %{reason: "#{length(triageable)} untriaged medium+ issues"}}
  end

  @doc "Check that no accepted issues at medium+ severity remain unresolved."
  @spec resolved?(term(), term()) :: {boolean(), map()}
  def resolved?(scope, _entity) do
    unresolved =
      Issues.list_by_status(scope, :accepted)
      |> Enum.filter(&(Issue.severity_index(&1.severity) <= Issue.severity_index(:medium)))

    if unresolved == [],
      do: {true, %{status: "No unresolved medium+ issues"}},
      else: {false, %{reason: "#{length(unresolved)} unresolved medium+ issues"}}
  end
end
