defmodule CodeMySpecWeb.UploadController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Uploads

  def create(conn, %{"filename" => filename, "content_type" => content_type}) do
    scope = conn.assigns.current_scope
    key = Uploads.generate_key(scope.active_project_id, filename)

    case Uploads.presigned_upload_url(key, content_type) do
      {:ok, url} ->
        json(conn, %{upload_url: url, s3_key: key})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to generate upload URL: #{inspect(reason)}"})
    end
  end
end
