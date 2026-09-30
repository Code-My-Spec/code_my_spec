defmodule CodeMySpec.Analysis.Run do
  @moduledoc """
  A recorded analyzer execution — the analysis run ledger.

  Each row answers "what ran, when, over which inputs, and how it went" for
  one analyzer source (`compiler`, `credo`, `exunit`, `spex`) in one project.

  `sobelow` is a real, working analyzer (`StaticAnalysis.Analyzers.Sobelow`,
  `Analysis.Runners.run/4`, `CmsHarness.Analysis`) deliberately NOT in this
  ledger yet. `stale_sources/1` in `Promotion` requires every member of
  `Run.sources()` to be fresh before any promotion, unconditionally, by
  design — the codebase's own comment there rejects config-based exemptions
  from that list on the grounds that narrowing it "would let a project
  promote a commit [a source] had never once run against." Adding `sobelow`
  here makes that same unconditional demand of a security scan, silently
  answering a question `9a78afa1` explicitly left open: whether a security
  scan should gate every promotion the same way a test suite does, given the
  two have different costs and cadences. Wire it in once that's decided, not
  as a side effect of registering it.
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

  # SHA-1, or SHA-256 in a repository that uses it.
  @sha ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @type t :: %__MODULE__{
          id: integer() | nil,
          source: String.t(),
          kind: :full | :partial,
          status: :running | :completed | :failed,
          input_fingerprint: String.t() | nil,
          completed_fingerprint: String.t() | nil,
          args: map() | nil,
          stats: map() | nil,
          requested_by: map() | nil,
          output: String.t() | nil,
          exit_status: integer() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          start_commit: String.t() | nil,
          start_tree_dirty: boolean() | nil,
          completed_commit: String.t() | nil,
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
    field :completed_fingerprint, :string
    field :args, :map
    field :stats, :map

    # Who asked, and why — a hook run carries `session_id`/`agent_id`/`hook`,
    # an MCP tool call carries `agent_id` alone, a manual trigger carries
    # neither. Nil means nothing was taught to tag that path yet, same as an
    # unset `args`/`stats`. See `CodeMySpec.Analysis.build_job/4`, which is
    # where every caller's `opts[:requested_by]` lands on the job that
    # eventually writes this row.
    field :requested_by, :map

    field :output, :string
    field :exit_status, :integer
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    # The working copy's commit when the analyzer started, whether its tree had
    # uncommitted changes then, and its commit when the analyzer finished.
    # Reported by the harness, which holds the checkout; nil when none did. A
    # tree that moved mid-run reads as `start_commit != completed_commit`.
    field :start_commit, :string
    field :start_tree_dirty, :boolean
    field :completed_commit, :string

    belongs_to :project, Project, type: :binary_id

    # Which working copy this run is about. A project can have several — a
    # worktree per branch is the ordinary case — and they analyse different
    # trees, so a run that is not attributed to one cannot be looked up or
    # closed without reaching into another checkout's work.
    field :working_copy_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Whether this run answers for a tree whose fingerprint is `current`.

  Either end of the run counts: the tree it started on, or the one it finished
  on when files moved while it ran. The one rule for "fresh" — the graph read
  only the input side while `Analysis.fresh?/2` read both, so a run that ended
  on the current tree passed evaluation and stayed stale in the graph, and a
  passed requirement was re-offered forever (849f8e7a).
  """
  @spec answers_for?(t() | nil, String.t() | nil) :: boolean()
  def answers_for?(%__MODULE__{status: :completed} = run, current) when is_binary(current),
    do: run.input_fingerprint == current or run.completed_fingerprint == current

  def answers_for?(_run, _current), do: false

  @doc "Known analyzer sources."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  The git state a harness reported for this run: `start_commit` and
  `start_tree_dirty` when it started, `completed_commit` when it finished.
  """
  @spec tree_changeset(t(), map()) :: Ecto.Changeset.t()
  def tree_changeset(run, attrs) do
    run
    |> cast(attrs, [:start_commit, :start_tree_dirty, :completed_commit])
    |> validate_format(:start_commit, @sha)
    |> validate_format(:completed_commit, @sha)
  end

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :source,
      :kind,
      :status,
      :input_fingerprint,
      :completed_fingerprint,
      :args,
      :stats,
      :requested_by,
      :output,
      :exit_status,
      :started_at,
      :finished_at,
      :project_id,
      :working_copy_id
    ])
    |> validate_required([:source, :kind, :status, :started_at, :project_id])
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:project_id)
  end
end
