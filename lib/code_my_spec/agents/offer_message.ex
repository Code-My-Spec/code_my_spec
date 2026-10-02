defmodule CodeMySpec.Agents.OfferMessage do
  @moduledoc "One delivery of an offer: the conversation message it was recorded as."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "offer_messages" do
    belongs_to :offer, CodeMySpec.Agents.Offer
    field :message_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(link \\ %__MODULE__{}, attrs) do
    link
    |> cast(attrs, [:offer_id, :message_id])
    |> validate_required([:offer_id, :message_id])
    |> foreign_key_constraint(:offer_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:offer_id, :message_id])
  end
end
