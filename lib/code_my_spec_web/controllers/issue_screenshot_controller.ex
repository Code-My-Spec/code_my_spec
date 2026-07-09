defmodule CodeMySpecWeb.IssueScreenshotController do
  @moduledoc """
  Serves a widget-reported issue's screenshot same-origin, streaming the bytes
  from our S3 bucket. Same-origin (not a presigned cross-origin URL) so it loads
  under the app's `img-src 'self'` CSP. Scoped to the current account's issues,
  and only serves a key under the issue's own `issues/<project>/` prefix.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Issues

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with issue when not is_nil(issue) <- Issues.get_issue(scope, id),
         %{"s3_key" => key} = shot <- screenshot(issue),
         true <- owned_key?(key, issue.project_id),
         {:ok, bytes} <- S3Client.get_object(bucket(), key) do
      conn
      |> put_resp_content_type(shot["content_type"] || "image/png", nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp screenshot(%{attachments: attachments}) when is_list(attachments) do
    Enum.find(attachments, &(is_map(&1) and &1["type"] == "screenshot" and is_binary(&1["s3_key"])))
  end

  defp screenshot(_), do: nil

  defp owned_key?(key, project_id) when is_binary(project_id),
    do: String.starts_with?(key, "issues/#{project_id}/")

  defp owned_key?(_key, _project_id), do: false

  defp bucket, do: Application.fetch_env!(:code_my_spec, :s3_bucket)
end
