defmodule CodeMySpec.Agents.Agent do
  @moduledoc """
  One coding agent CodeMySpec started, on one working copy, on one provider.

  `working_copy_id` is the working copy this agent runs in, and it is the key.
  Nothing joins on a path: `working_copy` and `harnesses.root` are both strings
  a device reported, and comparing two reported strings is how an agent ends up
  attached to a copy that does not exist — a symlink, a trailing slash or
  `/private/tmp` versus `/tmp` is enough. Two harness rows can also share a
  root, so a path match is ambiguous exactly where the answer matters.

  `working_copy` stays because the path is real and needed: `PiConfig` mints a
  configuration directory that must sit outside it, and the conversation key has
  to match what a lane pushes under. Reported, and not identifying — the same
  status `harnesses.root` has.

  `role` is which lane on that copy this agent is, and it is the half of the key
  that was missing. An `Ecto.Enum` since story 983 — the four types are fixed,
  and as a string a misspelling produced a row nothing would ever launch. A copy runs one or more agents; the harness already
  distinguishes them by role — `CodeMySpecLocalWeb.HarnessChannel` joins one
  session per copy and tracks Presence under the lane's role — so without it the
  reconcile found "the copy's agent" and a second lane overwrote the first.
  Defaulted here rather than in the migration, because the code that writes rows
  is what needs to see the default.

  `config_dir` is Pi's configuration directory for this agent
  (`PI_CODING_AGENT_DIR`), recorded rather than derived so a stop knows what to
  clean up even if the naming scheme changes underneath it. It is stored, and
  therefore assertable, because two rules depend on where it is: never inside
  the working copy, and never shared between tenants.

  `os_pid` is nullable on purpose. It is unknown between the row being written
  and the harness answering, and it stays null for an agent that failed to
  start — which is a different state from one that started and exited, and the
  two must not collapse into each other.

  It is a process **group** id rather than a bare pid: the harness starts each
  agent as its own group leader, so one signal takes the agent and every tool it
  spawned. `Workspaces.Runner.Local` reaps a bare pid with `pkill -TERM -P` and
  its own comment concedes that does not walk past one level of children.

  `os_boot_id` is what makes that number safe to act on. Group ids are reused,
  so one recorded before a reboot can name a stranger's process afterwards —
  and TERMing that is a failure nobody would ever trace back here. The pair is
  written together by `record_started/3` and read together: same boot **and**
  the group exists, or the agent is not ours to signal.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Projects.Project

  @statuses [:starting, :running, :stopped, :failed]
  # `:alloy` — renamed from `:pi`, John's call: "I completely backed out of
  # that. We're not doing that." The value stayed `:pi` in the schema and the
  # column after the product decision moved on, so "Pi" kept showing up
  # everywhere this field was displayed. Migration
  # `20260905000000_rename_pi_engine_to_alloy` updates existing rows.
  @engines [:alloy, :claude_code]

  # An enum rather than a free string, because a role is a fixed set and a typo
  # in one was silent: a row nothing launches, a setting nothing reads, and no
  # error anywhere to say so. Story 983.
  #
  # `spec_writer` is deliberately absent. Specs are written by the agent that
  # writes the code — John's call in that session — so requirements that used
  # to carry `role: :spec_writer` are re-tagged `:coding`.
  @roles [:main, :product, :coding, :qa]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          engine: atom() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          working_copy: String.t() | nil,
          role: atom() | nil,
          config_dir: String.t() | nil,
          history: [map()],
          os_pid: integer() | nil,
          os_boot_id: String.t() | nil,
          status: atom() | nil,
          continuous: boolean() | nil,
          tasks: [CodeMySpec.Sessions.Task.t()],
          working_copy_id: Ecto.UUID.t() | nil,
          turn_started_at: DateTime.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agents" do
    field :engine, Ecto.Enum, values: @engines, default: :alloy
    field :provider, :string
    # Which model this agent started on, recorded rather than looked up.
    # Story 983: pointing a type at a different model must not move an agent
    # already running — a turn whose provider changed underneath it is one
    # whose transcript stops making sense — so the answer has to be on the row
    # rather than read back from a setting that has since changed.
    field :model, :string
    field :working_copy, :string
    field :role, Ecto.Enum, values: @roles, default: :main

    # What this agent may call, as a list rather than as a rule read off its
    # role. `nil` means it predates scoping and could call everything — the one
    # state the column has that is not a list, and it goes when the old rows do.
    field :tools, {:array, :string}
    field :config_dir, :string

    # Held for the length of a start and never written down. The machine needs
    # the credential to run the agent; the row must not become a second place a
    # subscription lives. It used to reach the machine as a path to a directory
    # the *server* had written, which was only ever correct when the two were
    # the same box.
    field :credential, :map, virtual: true, redact: true

    # The conversation so far, for the length of a launch. Beside the
    # credential because it is the same kind of thing: the machine needs it to
    # run the agent, and the row must not become a second copy of a transcript
    # that already has a table.
    field :history, {:array, :map}, virtual: true, default: []
    field :os_pid, :integer
    field :os_boot_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :starting

    # Whether this agent keeps working when its turn ends.
    #
    # Story 538's R2: a mode on the agent, not a property of the work. It
    # decides what the stop hook does with the answer to "is there work of my
    # role" — never whether that question gets asked, which is the conflation
    # the rule was rewritten to end.
    #
    # False by default and entered deliberately. An agent staffed onto a working
    # copy when an epic lands has not been asked to run a loop, and starting one
    # on its behalf is the state `tap_out` exists to escape.
    field :continuous, :boolean, default: false

    field :working_copy_id, Ecto.UUID
    field :account_id, Ecto.UUID

    # When the turn currently running started, and nil when none is.
    #
    # The one fact that separates an agent thinking from an agent that has
    # stopped. A long reasoning turn produces nothing observable until it lands
    # — no message, no tool call, no edit — so from every other angle the two
    # are identical, and the remedy for the second destroys the first.
    #
    # A timestamp rather than a boolean because how long the turn has been
    # running is the interesting part: five seconds is normal and fifty minutes
    # is not, and a flag cannot tell them apart.
    field :turn_started_at, :utc_datetime_usec

    # The work this agent has claimed.
    #
    # Story 538's direction, and the end of an agent that could take turns and
    # never claim anything: a task was `embeds_many` on `Session`, so it could
    # not exist without one — and an agent we run has no session and no way to
    # get one. John: "we shouldn't need a session to create tasks, dude. You
    # should be keying the tasks to the agent and then embeds many on there."
    #
    # The same `Task` the session embeds, so one schema and one set of task
    # semantics serve both owners. Which list a task is in *is* its ownership,
    # so nothing needs a constraint to say so — and a constraint would have been
    # wrong anyway, because `Task.agent_id` already means the Claude Code
    # sub-agent a session's task is assigned to.
    embeds_many :tasks, CodeMySpec.Sessions.Task, on_replace: :delete

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The agent types. Fixed here so nothing can invent a fifth by typing it."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @spec engines() :: [atom()]
  def engines, do: @engines

  @doc """
  Add a task to this agent's list.

  The same shape as `Session.add_task/2`, deliberately: both owners hold the
  same `Task`, and a second set of task semantics is how the two would come to
  disagree about what `:active` means.

  `Task.agent_id` is left alone here, and that is the point of storing tasks
  this way: the list a task is in says who owns it, so a field repeating that
  is one more thing that can disagree with the row holding it. On a session's
  task the field still means what it always did — the Claude Code sub-agent it
  was assigned to — which is a question that does not arise for an agent we run,
  because we do not spawn sub-agents. John: *"we don't need agent ID ... we
  don't need the foreign key so don't care."*
  """
  @spec add_task(t(), map()) :: Ecto.Changeset.t()
  def add_task(%__MODULE__{} = agent, task_attrs) do
    task_attrs = Map.put_new(task_attrs, :id, Ecto.UUID.generate())

    agent
    |> change()
    |> put_embed(:tasks, (agent.tasks || []) ++ [task_attrs])
  end

  @doc "Update one of this agent's tasks by id."
  @spec update_task(t(), String.t(), map()) :: Ecto.Changeset.t()
  def update_task(%__MODULE__{} = agent, task_id, updates) do
    updated =
      Enum.map(agent.tasks || [], fn task ->
        if task.id == task_id, do: Map.merge(task, Map.new(updates)), else: task
      end)

    agent
    |> change()
    |> put_embed(:tasks, updated)
  end

  @doc "The task this agent is working, if any."
  @spec active_task(t()) :: CodeMySpec.Sessions.Task.t() | nil
  def active_task(%__MODULE__{tasks: tasks}) do
    Enum.find(tasks || [], &(&1.status == :active))
  end

  @doc "One of this agent's tasks by id."
  @spec find_task(t(), String.t()) :: CodeMySpec.Sessions.Task.t() | nil
  def find_task(%__MODULE__{tasks: tasks}, task_id) do
    Enum.find(tasks || [], &(&1.id == task_id))
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :engine,
      :provider,
      :model,
      :working_copy,
      :role,
      :tools,
      :config_dir,
      :os_pid,
      :os_boot_id,
      :status,
      :continuous,
      :turn_started_at,
      :working_copy_id,
      :project_id,
      :account_id
    ])
    |> validate_required([
      :engine,
      :provider,
      :working_copy,
      :role,
      :working_copy_id,
      :project_id,
      :account_id
    ])
    |> foreign_key_constraint(:working_copy_id)
    |> validate_config_dir_outside_working_copy()
    |> assoc_constraint(:project)
  end

  # Rule 4, enforced where it cannot be forgotten. A working copy is a git
  # repository whose purpose is to be committed and pushed — `agent.sh` runs
  # `git add -A` on a clean exit — so a credential directory inside the tree is
  # a scheduled leak rather than a risk of one. Cheap to check here, and the
  # alternative is trusting every future caller to construct the path correctly.
  defp validate_config_dir_outside_working_copy(changeset) do
    config_dir = get_field(changeset, :config_dir)
    working_copy = get_field(changeset, :working_copy)

    validate_containment(changeset, config_dir, working_copy)
  end

  defp validate_containment(changeset, nil, _working_copy), do: changeset
  defp validate_containment(changeset, _config_dir, nil), do: changeset

  defp validate_containment(changeset, config_dir, working_copy) do
    contained? =
      config_dir
      |> Path.expand()
      |> String.starts_with?(Path.expand(working_copy) <> "/")

    reject_containment(changeset, contained?)
  end

  defp reject_containment(changeset, false), do: changeset

  defp reject_containment(changeset, true) do
    add_error(
      changeset,
      :config_dir,
      "must sit outside the working copy — it holds auth.json, and the copy gets committed"
    )
  end
end
