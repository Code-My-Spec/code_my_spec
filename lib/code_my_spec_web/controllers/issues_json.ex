defmodule CodeMySpecWeb.IssuesJSON do
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Uploads

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
      source: issue.source,
      description: issue.description,
      status: issue.status,
      resolution: issue.resolution,
      story_id: issue.story_id,
      source_path: issue.source_path,
      reported_by_id: issue.reported_by_id,
      attachments: Enum.map(issue.attachments || [], &render_attachment/1),
      project_id: issue.project_id,
      account_id: issue.account_id,
      inserted_at: issue.inserted_at,
      updated_at: issue.updated_at
    }
  end

  defp render_attachment(att) do
    url =
      case Uploads.presigned_download_url(att.s3_key) do
        {:ok, url} -> url
        _ -> nil
      end

    %{
      filename: att.filename,
      content_type: att.content_type,
      size: att.size,
      url: url
    }
  end
end
