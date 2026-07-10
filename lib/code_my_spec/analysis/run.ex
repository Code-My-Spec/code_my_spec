defmodule CodeMySpec.Analysis.Run do
  @moduledoc """
  A recorded analyzer execution — the analysis run ledger.

  Each row answers "what ran, when, over which inputs, and how it went" for
  one analyzer source (`compiler`, `credo`, `exunit`, `spex`) in one project.
  The `input_fingerprint` is a hash over the File rows relevant to that source,
  computed at enqueue time (never at completion — mid-run edits must read as
  stale on the next check). A completed run whose fingerprint matches the
  current inputs means the persisted Problems for that source are current and
  the analyzer does not need to re-run.

  `kind` distinguishes canonical `:full` runs (bare / `--stale` — eligible to
  satisfy freshness) from `:partial` targeted runs (`mix test path/` — problems
  reconciled only for the files that ran, never freshness-making).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project

  @sources ~w(compiler credo exunit spex)

  @type t :: %__MODULE__{
          id: integer() | nil,
          source: String.t(),
          kind: :full | :partial,
          status: :running | :completed | :failed,
          input_fingerprint: String.t() | nil,
          args: map() | nil,
          stats: map() | nil,
          output: String.t() | nil,
          exit_status: integer() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          project_id: Ecto.UUID.t(),
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "analysis_runs" do
    field :source, :string
    field :kind, Ecto.Enum, values: [:full, :partial]
    field :status, Ecto.Enum, values: [:running, :completed, :failed]
    field :input_fingerprint, :string
    field :args, :map
    field :stats, :map
    field :output, :string
    field :exit_status, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :project, Project, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Known analyzer sources."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :source,
      :kind,
      :status,
      :input_fingerprint,
      :args,
      :stats,
      :output,
      :exit_status,
      :started_at,
      :finished_at,
      :project_id
    ])
    |> validate_required([:source, :kind, :status, :started_at, :project_id])
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:project_id)
  end
end
