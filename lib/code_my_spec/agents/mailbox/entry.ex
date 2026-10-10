defmodule CodeMySpec.Agents.Mailbox.Entry do
  @moduledoc "Ordered delivery ownership. Payload and visible delivery status live on the conversation message."
  use Ecto.Schema

  schema "agent_mailbox" do
    field :agent_id, Ecto.UUID
    field :message_id, Ecto.UUID
    field :delivery_ref, :string
    field :event, :string

    field :state, Ecto.Enum,
      values: [
        :queued,
        :claimed,
        :consumed,
        :completed,
        :interrupted,
        :withdrawn,
        :failed,
        :uncertain
      ]

    field :generation, :string
    field :claimed_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :diagnostic, :string
    timestamps(type: :utc_datetime_usec)
  end
end
