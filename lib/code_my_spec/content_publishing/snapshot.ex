defmodule CodeMySpec.ContentPublishing.Snapshot do
  @moduledoc """
  A single parsed content file in the local-first publishing snapshot (story
  712). Staged per-project in the local SQLite DB; `parse_status`/`parse_errors`
  capture per-file results so a malformed file surfaces as data, not an
  exception. Decoupled from the soon-deleted `ContentAdmin` schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project

  @type t :: %__MODULE__{}

  schema "content_snapshots" do
    field :raw_content, :string
    field :processed_content, :string
    field :parse_status, Ecto.Enum, values: [:success, :error]
    field :parse_errors, :map
    field :metadata, :map, default: %{}

    belongs_to :project, Project, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:raw_content, :processed_content, :parse_status, :parse_errors, :metadata, :project_id])
    |> validate_required([:raw_content, :parse_status, :project_id])
  end
end
