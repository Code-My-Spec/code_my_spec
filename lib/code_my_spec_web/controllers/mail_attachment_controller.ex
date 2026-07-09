defmodule CodeMySpecWeb.MailAttachmentController do
  @moduledoc """
  Serves an inbound email's stored attachment by redirecting to a short-lived
  presigned S3 URL. The attachment is looked up scoped to the mailboxes the
  current member may see, so one member can't fetch another project's files.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Mail

  def show(conn, %{"id" => id}) do
    case Mail.get_attachment(conn.assigns.current_scope, id) do
      nil ->
        conn |> put_status(:not_found) |> text("Not found")

      attachment ->
        case Mail.attachment_download_url(attachment) do
          {:ok, url} -> redirect(conn, external: url)
          {:error, _reason} -> conn |> put_status(:bad_gateway) |> text("Attachment unavailable")
        end
    end
  end
end
