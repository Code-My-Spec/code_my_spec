defmodule CodeMySpec.Billing.StripeEvent do
  @moduledoc """
  One row per Stripe event we have already processed.

  Stripe delivers webhooks at least once — a redelivery is normal, not a fault.
  The controller inserts this row before dispatching, so the unique index on
  `event_id` is what makes a second delivery a no-op rather than a second
  grant.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          event_id: String.t(),
          type: String.t(),
          inserted_at: DateTime.t() | nil
        }

  schema "stripe_events" do
    field :event_id, :string
    field :type, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :type])
    |> validate_required([:event_id, :type])
    |> unique_constraint(:event_id)
  end
end
