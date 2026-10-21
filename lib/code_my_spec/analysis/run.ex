defmodule CodeMySpec.Analysis.Run do
  @moduledoc """
  A recorded analyzer execution — the analysis run ledger.

  Each row answers "what ran, when, over which inputs, and how it went" for
  one analyzer source (`compiler`, `credo`, `exunit`, `spex`) in one project.

  Product decided in questions `2b219959` and `4f6303c2`, against story 983
  criterion 1774: promotion and ready-for-QA require the fixed four sources
  `compiler`, `credo`, `exunit`, and `spex`. Sobelow does not gate either.
  Keep it out of `Run.sources()` and controller `@valid_sources` lists.
  Do not add a per-project switch to include it in the gate.

  Sobelow remains a working analyzer and can report findings as problems
  without blocking. Adding it to the gate requires a new criterion on
  story 983 for the user to decide, not a registration change. If a real
  security finding reaches main because Sobelow did not gate it, file an
  issue with that finding. This resolves the policy question in `9a78afa1`.

  The latest completed `:full` run answers for its source, however old. Which
  commit it answers for is `start_commit`/`completed_commit`, and the promote
  gate reads that (`at_commit?/2`, 28d72f8a) — the one rule for "current".

  `kind` distinguishes canonical `:full` runs (bare args, the stop hook's
  whole-project sweep) from `:partial` targeted runs (`mix test path/`,
  rewritten by the PreToolUse hook). A partial records its output and stats for
  the model to read back but leaves Problems untouched, and
  `latest_full_run/2` filters it out so it can never answer for a source.
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
          args: map() | nil,
          stats: map() | nil,
          requested_by: map() | nil,
          requester_agent_id: String.t() | nil,
          orphaned: boolean(),
          settled: String.t() | nil,
          output: String.t() | nil,
          exit_status: integer() | nil,
          started_at: DateTime.t(),
          began_at: DateTime.t() | nil,
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
    field :args, :map
    field :stats, :map

    # Who asked, and why — a hook run carries `session_id`/`agent_id`/`hook`,
    # an MCP tool call carries `agent_id` alone, a manual trigger carries
    # neither. Nil means nothing was taught to tag that path yet, same as an
    # unset `args`/`stats`. See `CodeMySpec.Analysis.build_job/4`, which is
    # where every caller's `opts[:requested_by]` lands on the job that
    # eventually writes this row.
    field :requested_by, :map

    # The agent owed this run's answer: `requested_by`'s `agent_id`, an agent
    # UUID or a Claude Code subagent id. Others waiting on it are `waiters`.
    field :requester_agent_id, :string
    has_many :waiters, CodeMySpec.Analysis.RunWaiter

    # Its harness went away while it ran, and how that was settled since:
    # reopened, run again, or given up on (`Analysis.resume_orphaned/2`).
    field :orphaned, :boolean, default: false
    field :settled, :string

    field :output, :string
    field :exit_status, :integer
    field :started_at, :utc_datetime_usec

    # When the harness got a machine slot and the analyzer began; `started_at`
    # is when it was requested. A `:running` run with none is queued, waiting
    # for a slot (bf627680).
    field :began_at, :utc_datetime_usec
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

  @doc "Requested but not yet begun: waiting for a machine slot."
  @spec queued?(t()) :: boolean()
  def queued?(%__MODULE__{status: :running, began_at: nil}), do: true
  def queued?(_run), do: false

  @doc """
  Whether this run answers for `commit`: completed, started on a clean tree at
  `commit`, and finished there (28d72f8a). The promote gate's rule, in place of
  fingerprint freshness.
  """
  @spec at_commit?(t() | nil, String.t() | nil) :: boolean()
  def at_commit?(
        %__MODULE__{
          status: :completed,
          start_commit: commit,
          completed_commit: commit,
          start_tree_dirty: false
        },
        commit
      )
      when is_binary(commit),
      do: true

  def at_commit?(_run, _commit), do: false

  @doc "Known analyzer sources."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  What a harness reported for this run: `began_at`, `start_commit` and
  `start_tree_dirty` when it started, `completed_commit` when it finished.
  """
  @spec tree_changeset(t(), map()) :: Ecto.Changeset.t()
  def tree_changeset(run, attrs) do
    run
    |> cast(attrs, [:began_at, :start_commit, :start_tree_dirty, :completed_commit])
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
      :args,
      :stats,
      :requested_by,
      :orphaned,
      :exit_status,
      :started_at,
      :finished_at,
      :project_id,
      :working_copy_id
    ])
    # Empty stdout is a recorded result; nil means no output was retained.
    |> cast(attrs, [:output], empty_values: [])
    |> put_requester()
    |> validate_required([:source, :kind, :status, :started_at, :project_id])
    |> validate_inclusion(:source, @sources)
    |> foreign_key_constraint(:project_id)
  end

  defp put_requester(changeset) do
    case get_field(changeset, :requested_by) do
      %{} = by -> put_change(changeset, :requester_agent_id, by["agent_id"] || by[:agent_id])
      _ -> changeset
    end
  end
end
