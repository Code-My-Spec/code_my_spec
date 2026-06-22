defmodule CodeMySpec.Mail.Email do
  @moduledoc """
  A persisted email in a mailbox — inbound (received) or outbound (sent).

  CMS keeps its own copy (metadata + text/html body) so a mailbox's history
  outlives the provider's ~30-day retention window. `correspondent` is the
  other party's address (inbound: the sender; outbound: the recipient) and is
  what threads a mailbox per-correspondent. Attachments are not stored in v1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "emails" do
    field :direction, Ecto.Enum, values: [:inbound, :outbound]
    field :from_address, :string
    field :to_address, :string
    field :correspondent, :string
    field :subject, :string
    field :body_text, :string
    field :body_html, :string
    field :provider_id, :string
    field :message_id, :string
    field :in_reply_to, :string

    belongs_to :mailbox, CodeMySpec.Mail.Mailbox, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(email, attrs) do
    email
    |> cast(attrs, [
      :direction,
      :from_address,
      :to_address,
      :correspondent,
      :subject,
      :body_text,
      :body_html,
      :provider_id,
      :message_id,
      :in_reply_to,
      :mailbox_id,
      :inserted_at
    ])
    |> validate_required([:direction, :correspondent, :mailbox_id])
  end
end
