defmodule CodeMySpec.Events.Event do
  @moduledoc """
  Generic event row. `event_type` is the discriminator; `data` is an
  open JSON blob whose shape is event-specific (user_id, project_id,
  payload metadata, etc.). Inserts are append-only — no updates.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_type: String.t() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil
        }

  schema "events" do
    field :event_type, :string
    field :data, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :data])
    |> validate_required([:event_type])
  end
end
