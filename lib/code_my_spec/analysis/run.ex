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

  `kind` distinguishes canonical `:full` runs (bare args, the stop hook's
  whole-project sweep — eligible to satisfy freshness) from `:partial` targeted
  runs (`mix test path/`, rewritten by the PreToolUse hook). A partial records
  its output and stats for the model to read back but leaves Problems
  untouched, and `latest_full_run/2` filters it out so it can never make a
  source look fresh.
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
    # `:superseded` is not a failure. It is a run that never ran, because one
    # for the same source was already queued and will answer for both. Kept
    # apart from `:failed` because the two were indistinguishable in the
    # ledger, and everything reading it had to guess: a duplicate enqueue made
    # its source report `failed` when nothing had failed, and — until
    # `latest_completed_run/2` — made a good result read stale. 14 of these in
    # half an hour on one harness.
    field :status, Ecto.Enum, values: [:running, :completed, :failed, :superseded]
    field :input_fingerprint, :string
    field :args, :map
    field :stats, :map
    field :output, :string
    field :exit_status, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :project, Project, type: :binary_id

    # Which working copy this run is about. A project can have several — a
    # worktree per branch is the ordinary case — and they analyse different
    # trees, so a run that is not attributed to one cannot be looked up or
    # closed without reaching into another checkout's work.
    field :harness_id, :binary_id

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
      :project_id,
      :harness_id
    ])
    |> validate_required([:source, :kind, :status, :started_at, :project_id])
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:project_id)
  end
end
