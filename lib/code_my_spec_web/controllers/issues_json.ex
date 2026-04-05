defmodule CodeMySpecWeb.IssuesJSON do
  alias CodeMySpec.Issues.Issue

  def index(%{issues: issues}) do
    %{data: for(issue <- issues, do: data(issue))}
  end

  def show(%{issue: issue}) do
    %{data: data(issue)}
  end

  defp data(%Issue{} = issue) do
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
      source_path: issue.source_path,
      project_id: issue.project_id,
      account_id: issue.account_id,
      inserted_at: issue.inserted_at,
      updated_at: issue.updated_at
    }
  end
end
