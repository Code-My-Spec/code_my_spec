defmodule CodeMySpecWeb.ConversationAttachmentController do
  @moduledoc """
  Serves a chat message's attachment same-origin (streaming from S3) so it loads
  under the operator inbox's `img-src 'self'` CSP. Scoped to the current
  account's conversations, and only serves a key under the message's own
  project `chat/` prefix.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Conversations

  def show(conn, %{"message_id" => message_id, "index" => index}) do
    scope = conn.assigns.current_scope

    with message when not is_nil(message) <- Conversations.get_message(scope, message_id),
         {idx, _} <- Integer.parse(index),
         %{"s3_key" => key} = attachment <- Enum.at(Message.files(message), idx),
         true <- owned_key?(key, message.conversation.project_id),
         {:ok, bytes} <- S3Client.get_object(bucket(), key) do
      conn
      |> put_resp_content_type(attachment["content_type"] || "application/octet-stream", nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> maybe_download(attachment)
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  # Non-images download with their original filename; images render inline.
  defp maybe_download(conn, %{"content_type" => "image/" <> _}), do: conn

  defp maybe_download(conn, %{"filename" => name}) when is_binary(name) do
    put_resp_header(
      conn,
      "content-disposition",
      ~s(attachment; filename="#{Path.basename(name)}")
    )
  end

  defp maybe_download(conn, _attachment), do: conn

  defp owned_key?(key, project_id) when is_binary(key) and is_binary(project_id),
    do: String.starts_with?(key, "chat/#{project_id}/")

  defp owned_key?(_key, _project_id), do: false

  defp bucket, do: Application.fetch_env!(:code_my_spec, :s3_bucket)
end
