defmodule CodeMySpec.Mail.Attachments do
  @moduledoc """
  Copies an inbound email's attachments out of Resend and into our own S3
  bucket, then records them as `EmailAttachment` rows.

  Resend discards inbound attachment bytes after ~30 days and only ever hands
  them out behind short-lived signed URLs (the `email.received` webhook names
  the files but carries no bytes). So on receipt we list the attachments, pull
  each one down from its signed `download_url` while it's still valid, and PUT
  the bytes into `:s3_bucket` under a key we control — the same bucket used for
  issue uploads. From then on the mailbox renders attachments from our storage,
  independent of the provider's retention window.

  Best-effort by design: the persisted `Email` is already the mailbox's source
  of truth, so any failure copying an attachment is logged and skipped rather
  than surfaced to the caller. Idempotent by `(email_id, provider_attachment_id)`
  so a re-delivered webhook or a `sync_inbound` pass never stores a file twice.
  """

  require Logger

  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Mail.{Email, EmailAttachment, ResendClient}
  alias CodeMySpec.Repo

  @doc """
  Store every attachment on an inbound `Email` (matched by its Resend receiving
  id). Returns the list of stored/known `EmailAttachment` structs. A no-op for
  outbound mail or an email without a provider id.
  """
  @spec store_inbound(Email.t()) :: [EmailAttachment.t()]
  def store_inbound(%Email{provider_id: rid} = email) when is_binary(rid) do
    case ResendClient.list_received_attachments(rid) do
      {:ok, metas} ->
        metas
        |> Enum.map(&store_one(email, &1))
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("Mail.Attachments: could not list attachments for #{rid}: #{inspect(reason)}")
        []
    end
  end

  def store_inbound(%Email{}), do: []

  defp store_one(%Email{} = email, meta) do
    provider_id = meta["id"]

    case existing(email.id, provider_id) do
      %EmailAttachment{} = existing -> existing
      nil -> download_and_store(email, meta, provider_id)
    end
  end

  defp download_and_store(%Email{} = email, meta, provider_id) do
    with url when is_binary(url) <- meta["download_url"],
         {:ok, bytes} <- ResendClient.download_attachment(url),
         key = s3_key(email, provider_id, meta["filename"]),
         :ok <- put(key, bytes, meta["content_type"]),
         {:ok, attachment} <- insert(email, meta, provider_id, key) do
      attachment
    else
      other ->
        Logger.warning(
          "Mail.Attachments: could not store attachment #{inspect(provider_id)} " <>
            "for email #{email.id}: #{inspect(other)}"
        )

        nil
    end
  end

  defp existing(_email_id, nil), do: nil

  defp existing(email_id, provider_id) do
    Repo.get_by(EmailAttachment, email_id: email_id, provider_attachment_id: provider_id)
  end

  defp put(key, bytes, content_type) do
    S3Client.put_object(bucket(), key, bytes,
      content_type: content_type || "application/octet-stream"
    )
  end

  defp insert(%Email{} = email, meta, provider_id, key) do
    %EmailAttachment{}
    |> EmailAttachment.changeset(%{
      email_id: email.id,
      provider_attachment_id: provider_id,
      filename: meta["filename"],
      content_type: meta["content_type"],
      content_disposition: meta["content_disposition"],
      content_id: meta["content_id"],
      size: meta["size"],
      s3_key: key
    })
    |> Repo.insert()
  end

  # A stable, collision-free key under our bucket. The attachment id keeps two
  # files with the same name apart; a sanitized filename keeps the key readable.
  defp s3_key(%Email{} = email, provider_id, filename) do
    id = provider_id || Ecto.UUID.generate()
    "mail/#{email.mailbox_id}/#{email.id}/#{id}/#{safe_filename(filename)}"
  end

  defp safe_filename(nil), do: "attachment"

  defp safe_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 200)
    |> case do
      "" -> "attachment"
      cleaned -> cleaned
    end
  end

  defp bucket, do: Application.fetch_env!(:code_my_spec, :s3_bucket)
end
