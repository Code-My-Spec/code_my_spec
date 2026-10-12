defmodule CodeMySpec.Analysis.ValidationHold do
  @moduledoc "A durable serial validation authorization and its terminal handoff."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "validation_holds" do
    field(:project_id, :binary_id)
    field(:owner_agent_id, :binary_id)
    field(:reason, :string)
    field(:affected_copy_ids, {:array, :binary_id})
    field(:authorized_copy_id, :binary_id)
    field(:source, :string)
    field(:args, {:array, :string}, default: [])
    field(:next_agent_id, :binary_id)

    field(:status, Ecto.Enum,
      values: [:held, :authorized, :running, :unknown, :awaiting_handoff, :released]
    )

    field(:run_id, :integer)
    field(:outcome, :map)
    field(:history, :map, default: %{"events" => []})
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(hold, attrs) do
    hold
    |> cast(attrs, [
      :project_id,
      :owner_agent_id,
      :reason,
      :affected_copy_ids,
      :authorized_copy_id,
      :source,
      :args,
      :next_agent_id,
      :status,
      :run_id,
      :outcome,
      :history
    ])
    |> validate_required([
      :project_id,
      :owner_agent_id,
      :reason,
      :affected_copy_ids,
      :status,
      :next_agent_id
    ])
    |> validate_length(:affected_copy_ids, min: 1)
    |> validate_inclusion(:source, CodeMySpec.Analysis.Run.sources())
    |> unique_constraint(:project_id, name: :validation_holds_one_open_per_project)
  end
end
