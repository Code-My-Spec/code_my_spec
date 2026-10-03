defmodule CodeMySpecWeb.QaEvidenceController do
  @moduledoc """
  Serves a QA attempt's uploaded evidence same-origin, streaming the bytes
  from our S3 bucket. Same-origin (not a presigned cross-origin URL) so it
  loads under the app's `img-src 'self'` CSP — the same reasoning
  `IssueScreenshotController` already follows for issue screenshots.

  Scoped to the current account's QA attempts (`QaAttempts.get/2` joins
  through the attempt's story to the active project), and only serves a
  key under that attempt's own `qa/<project_id>/<attempt_id>/` prefix —
  belt and suspenders alongside the scoped lookup, same as the issue
  screenshot controller's own `owned_key?/2`.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Qa.QaAttempts

  def show(conn, %{"attempt_id" => attempt_id, "name" => name}) do
    scope = conn.assigns.current_scope

    with attempt when not is_nil(attempt) <- QaAttempts.get(scope, attempt_id),
         %{} = evidence <- Enum.find(attempt.evidence || [], &(&1.name == name)),
         true <- owned_key?(evidence.s3_key, attempt_id),
         {:ok, bytes} <- S3Client.get_object(bucket(), evidence.s3_key) do
      conn
      |> put_resp_content_type(evidence.content_type || "application/octet-stream", nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp owned_key?(key, attempt_id) when is_binary(key),
    do: String.starts_with?(key, "qa/") and String.contains?(key, "/#{attempt_id}/")

  defp owned_key?(_key, _attempt_id), do: false

  defp bucket, do: Application.fetch_env!(:code_my_spec, :s3_bucket)
end
