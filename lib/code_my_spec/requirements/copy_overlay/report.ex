defmodule CodeMySpec.Requirements.CopyOverlay.Report do
  @moduledoc """
  A checkout's last overlay report, one row per copy. `verdicts` is an erlang
  term written and read only through `CopyOverlay`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:working_copy_id, :binary_id, autogenerate: false}

  schema "copy_overlays" do
    field :project_id, :binary_id
    field :read_model, :string
    field :head, :string
    field :behind, :integer
    field :dirty, :boolean
    field :verdicts, :binary
    field :reported_at, :utc_datetime_usec
    field :mismatches, :integer
    field :clean_reports, :integer
    field :compared_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields ~w(project_id read_model head behind dirty verdicts reported_at mismatches clean_reports compared_at)a

  def changeset(report, attrs) do
    report
    |> cast(attrs, @fields)
    |> validate_required([:project_id, :read_model, :verdicts, :reported_at, :clean_reports])
  end
end
