defmodule CodeMySpec.PromotionQueue.Entry do
  @moduledoc """
  One enqueued candidate: a working copy at a commit, waiting to be gated in a
  batch and landed on main.

  `:queued` until a batch takes it, `:gating` while it is in one, then
  `:landed` or `:ejected` — or back to `:queued` when a red batch is split and
  it was not the half being gated.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:queued, :gating, :landed, :ejected, :cancelled]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t(),
          working_copy_id: Ecto.UUID.t(),
          commit: String.t(),
          story_number: integer() | nil,
          requested_by_agent_id: Ecto.UUID.t() | nil,
          restart: boolean(),
          status: atom(),
          batch_id: Ecto.UUID.t() | nil,
          result: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "promotion_queue_entries" do
    field :project_id, :binary_id
    field :working_copy_id, :binary_id
    field :commit, :string
    field :story_number, :integer
    field :requested_by_agent_id, :binary_id
    field :restart, :boolean
    field :status, Ecto.Enum, values: @statuses
    field :batch_id, :binary_id
    field :result, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc "A new candidate, queued."
  def enqueue_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :project_id,
      :working_copy_id,
      :commit,
      :story_number,
      :requested_by_agent_id,
      :restart
    ])
    |> put_change(:status, :queued)
    |> validate_required([:project_id, :working_copy_id, :commit, :restart, :status])
  end

  @doc "A move between states, with the batch it is in and the outcome so far."
  def status_changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:status, :batch_id, :result])
    |> validate_required([:status])
  end
end
