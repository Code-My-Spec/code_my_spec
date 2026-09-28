defmodule CodeMySpecWeb.IssuesJSON do
  alias CodeMySpec.Issues.Issue

  def index(%{issues: issues} = assigns) do
    numbers = Map.get(assigns, :story_numbers, %{})
    %{data: for(issue <- issues, do: data(issue, numbers))}
  end

  def show(%{issue: issue} = assigns) do
    %{data: data(issue, Map.get(assigns, :story_numbers, %{}))}
  end

  defp data(%Issue{} = issue, numbers) do
    %{
      id: issue.id,
      title: issue.title,
      severity: issue.severity,
      scope: issue.scope,
      description: issue.description,
      source: issue.source,
      status: issue.status,
      resolution: issue.resolution,
      story_id: issue.story_id,
      story_number: Map.get(numbers, issue.story_id),
      source_path: issue.source_path,
      project_id: issue.project_id,
      account_id: issue.account_id,
      inserted_at: issue.inserted_at,
      updated_at: issue.updated_at
    }
  end
end
