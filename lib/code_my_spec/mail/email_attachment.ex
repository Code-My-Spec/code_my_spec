defmodule CodeMySpec.Mail.EmailAttachment do
  @moduledoc """
  A file attached to an inbound email, persisted to our own S3 bucket.

  Resend keeps inbound attachment bytes for only ~30 days and hands them out
  behind short-lived signed URLs; the metadata-only webhook doesn't carry them
  at all. So on receipt we fetch the bytes from Resend's signed
  `download_url` and copy them into our bucket (`s3_key`), keeping the metadata
  here so a mailbox's attachments outlive the provider's retention window and
  render from a URL we control.

  `provider_attachment_id` is Resend's attachment id, used to dedupe so a
  re-synced or re-delivered message doesn't store the same file twice.
  `content_disposition` (`"inline"` vs `"attachment"`) and `content_id`
  distinguish inline images (referenced from the HTML body by `cid:`) from
  regular downloads.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "email_attachments" do
    field :provider_attachment_id, :string
    field :filename, :string
    field :content_type, :string
    field :content_disposition, :string
    field :content_id, :string
    field :size, :integer
    field :s3_key, :string

    belongs_to :email, CodeMySpec.Mail.Email, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :provider_attachment_id,
      :filename,
      :content_type,
      :content_disposition,
      :content_id,
      :size,
      :s3_key,
      :email_id
    ])
    |> validate_required([:s3_key, :email_id])
    |> unique_constraint([:email_id, :provider_attachment_id],
      name: :email_attachments_email_id_provider_attachment_id_index
    )
  end

  @doc "True for an inline attachment referenced from the HTML body by `cid:`."
  def inline?(%__MODULE__{content_disposition: "inline"}), do: true
  def inline?(%__MODULE__{}), do: false
end
