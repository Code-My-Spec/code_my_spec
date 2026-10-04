defmodule CodeMySpec.PromotionQueue.Entry do
  @moduledoc """
  One enqueued candidate: a working copy at a commit, waiting to be gated in a
  batch and landed on main.

  `:queued` until a batch takes it, `:gating` while it is in one, then
  `:landed` or `:ejected` — or back to `:queued` when a red batch is split and
  it was not the half being gated.

  Its subject is what it promotes: a story (by number), an issue's fix (by id),
  or nothing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:queued, :gating, :landed, :ejected, :cancelled]
  @subject_types [:story, :issue]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t(),
          working_copy_id: Ecto.UUID.t(),
          commit: String.t(),
          subject_type: :story | :issue | nil,
          subject_id: String.t() | nil,
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
    field :subject_type, Ecto.Enum, values: @subject_types
    field :subject_id, :string
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
      :subject_type,
      :subject_id,
      :requested_by_agent_id,
      :restart
    ])
    |> put_change(:status, :queued)
    |> validate_required([:project_id, :working_copy_id, :commit, :restart, :status])
  end

  @doc "The story number an entry promotes, or nil."
  @spec story_number(t()) :: integer() | nil
  def story_number(%__MODULE__{subject_type: :story, subject_id: id}), do: String.to_integer(id)
  def story_number(%__MODULE__{}), do: nil

  @doc "The issue id an entry promotes the fix of, or nil."
  @spec issue_id(t()) :: Ecto.UUID.t() | nil
  def issue_id(%__MODULE__{subject_type: :issue, subject_id: id}), do: id
  def issue_id(%__MODULE__{}), do: nil

  @doc "What an entry promotes, in a few words."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{subject_type: :story, subject_id: number, commit: commit}),
    do: "story #{number} (#{String.slice(commit, 0, 12)})"

  def describe(%__MODULE__{subject_type: :issue, subject_id: id, commit: commit}),
    do: "the fix for issue #{id} (#{String.slice(commit, 0, 12)})"

  def describe(%__MODULE__{commit: commit}), do: String.slice(commit, 0, 12)

  @doc "A move between states, with the batch it is in and the outcome so far."
  def status_changeset(%__MODULE__{} = entry, attrs) do
    entry
    |> cast(attrs, [:status, :batch_id, :result])
    |> validate_required([:status])
  end
end
