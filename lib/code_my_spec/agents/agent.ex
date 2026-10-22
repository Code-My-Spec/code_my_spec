defmodule CodeMySpec.Agents.Agent do
  @moduledoc """
  One coding agent CodeMySpec started, on one working copy, on one provider.

  `working_copy_id` is the working copy this agent runs in and, with `role`,
  the key: one agent per role per copy. Nothing joins on the reported
  `working_copy` path.

  `working_copy` is the reported path, kept because the conversation key and
  the agent's configuration directory are placed relative to it.

  `config_dir` is recorded rather than derived, so a stop knows what to clean
  up. It must sit outside the working copy (validated).

  `os_pid` is a process **group** id, nullable: unknown until the harness
  answers, and null for an agent that failed to start. `os_boot_id` is written
  with it by `record_started/3` and read with it: same boot and the group
  exists, or the agent is not ours to signal.

  See knowledge/agents/coordination, "The agent row".
  """

  # A schema leaf: contexts below Agents (TaskOwner, Notifications, Qa) read
  # and match agent rows without depending on Agents.
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Agents.RoleProfile, CodeMySpec.Repo],
    exports: [Task, TaskType]

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Repo.References

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Projects.Project

  @statuses [:starting, :running, :stopped, :failed]

  # `:reaped`: nothing confirmed the process ended on purpose (no report, or a
  # machine that could not be asked). `:stopped`: somebody asked. Nil: unknown.
  @stopped_reasons [:reaped, :stopped]
  @engines [:alloy, :claude_code, :codex]
  # Sessions a person runs in a terminal: agents on the harness, not ones we start.
  @terminal_engines [:claude_code, :codex]

  # An enum: a misspelt role was a row nothing launches. There is no
  # `spec_writer`; the coding agent writes specs.
  @roles CodeMySpec.Agents.RoleProfile.roles()

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
          stopped_reason: atom() | nil,
          git_rewrite_at: DateTime.t() | nil,
          current_tool: String.t() | nil,
          turn_tool_count: non_neg_integer() | nil,
          waiting_since: DateTime.t() | nil,
          off_at: DateTime.t() | nil,
          off_by: String.t() | nil,
          off_reason: String.t() | nil,
          retired_at: DateTime.t() | nil,
          retired_by: String.t() | nil,
          retired_reason: String.t() | nil,
          continuous: boolean() | nil,
          tasks: [CodeMySpec.Agents.Agent.Task.t()],
          working_copy_id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          epic_id: Ecto.UUID.t() | nil,
          issue_id: Ecto.UUID.t() | nil,
          team_free_at: DateTime.t() | nil,
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
    field(:execution_mode, Ecto.Enum, values: [:working_copy, :detached], default: :working_copy)
    # A terminal Claude Code session's own session id (story 1122): how a
    # resumed session finds its agent again, and how its tool calls name it.
    field :engine_session_id, :string
    # The file that session writes what it says and spends to, as its SessionStart
    # hook named it: where a re-attached harness reads it from.
    field :transcript_path, :string
    # When a terminal session last ran a Bash command able to move HEAD (rebase,
    # pull, checkout, ...). `Validation` reads it to tell inherited history from
    # this turn's work when no edits were recorded.
    field :git_rewrite_at, :utc_datetime_usec
    # The tool the agent is running now, as one line, or nil. Set by a tool call
    # starting and cleared by it ending or the turn ending.
    field :current_tool, :string
    field :turn_tool_count, :integer
    # Since when a terminal session has been waiting on its person (a permission
    # prompt), or nil. It cannot take work while it is.
    field :waiting_since, :utc_datetime_usec
    field :provider, :string
    # The model this agent started on, recorded: changing the role's setting
    # must not move an agent already running.
    field :model, :string
    field :working_copy, :string
    field :role, Ecto.Enum, values: @roles, default: :main

    # What this agent launched with (`nil` predates scoping). Enforcement
    # derives tools per call, not from this column.
    field :tools, {:array, :string}
    field :config_dir, :string

    # Held for the length of a start and never written down: the row must not
    # become a second place a subscription lives.
    field :credential, :map, virtual: true, redact: true

    # The conversation so far, for the length of a launch; never stored (the
    # transcript has its own table).
    field :history, {:array, :map}, virtual: true, default: []
    field :os_pid, :integer
    field :os_boot_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :starting
    field :stopped_reason, Ecto.Enum, values: @stopped_reasons

    # Intent, apart from `status` and `stopped_reason` (what the process did).
    # `off_at` set means off: nothing is delivered and nothing restarts it until
    # `Agents.turn_on_agent/2` clears all three.
    field :off_at, :utc_datetime_usec
    field :off_by, :string
    field :off_reason, :string

    # Retired is a different intent from off: the agent is gone for good and its
    # seat is free. Set by `Agents.retire_agent/3`, never cleared; the row stays
    # for its history.
    field :retired_at, :utc_datetime_usec
    field :retired_by, :string
    field :retired_reason, :string

    # Whether this agent keeps working when its turn ends: decides what the stop
    # hook does with "is there work of my role", never whether it is asked.
    # False by default; a staffed agent has not been asked to run a loop.
    field :continuous, :boolean, default: false

    field :working_copy_id, Ecto.UUID
    field :account_id, Ecto.UUID

    # Coding and QA on a copy share their active story. Explicit issue-bag
    # assignment clears it for the whole team. `stories.working_copy_id`
    # records checkout reservations, separately from promotion history.
    field :story_id, :id
    field :epic_id, Ecto.UUID

    # Shared priority within the working copy's assigned issue bag.
    # Membership lives on Issue.assigned_working_copy_id. Each role can claim
    # other eligible bag members while this priority waits on its teammate.
    field :issue_id, Ecto.UUID
    field :mailbox_generation, :string
    # When this team last became free of its last issue with no story to
    # fall back to. Set, the team is told it is waiting for main's next
    # assignment rather than offered project-level work.
    field :team_free_at, :utc_datetime_usec

    # When the running turn started; nil when none is. The one fact that
    # separates an agent thinking from one that has stopped; a timestamp because
    # how long it has run is the interesting part.
    field :turn_started_at, :utc_datetime_usec
    # Derived for display, never stored: `Agents.with_lifecycle/2` sets it from
    # `Agents.Presence` (`:running | :gave_up | :starting | :off | :retired`),
    # and `gave_up` to what the harness said when it gave up on the agent.
    field :lifecycle, :any, virtual: true
    field :gave_up, :map, virtual: true

    # The offer this agent was last handed and did not take: a fingerprint, so
    # the agent wakes when the work changes; the timestamp bounds the hold.
    # See knowledge/agents/coordination, "The agent row".
    field :declined_offer, :string
    field :declined_offer_at, :utc_datetime_usec
    field :declined_offer_count, :integer

    # The provider's own words refusing this agent's last turn (usage limit,
    # auth, model), when, and the retry time if they named one. Nil once a turn
    # ends without a refusal.
    field :provider_refusal, :string
    field :provider_refused_at, :utc_datetime_usec
    field :provider_retry_at, :utc_datetime_usec

    # The work this agent has claimed: the same `Task` a session embeds. Which
    # list a task is in is its ownership.
    embeds_many :tasks, CodeMySpec.Agents.Agent.Task, on_replace: :delete

    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec stopped_reasons() :: [atom()]
  def stopped_reasons, do: @stopped_reasons

  @doc "The agent types. Fixed here so nothing can invent a fifth by typing it."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @spec engines() :: [atom()]
  def engines, do: @engines

  @doc "The engines that are a person's terminal session."
  @spec terminal_engines() :: [atom()]
  def terminal_engines, do: @terminal_engines

  @doc "Whether this agent is a session a person runs in a terminal."
  @spec terminal?(t() | atom() | nil) :: boolean()
  def terminal?(%__MODULE__{engine: engine}), do: terminal?(engine)
  def terminal?(engine), do: engine in @terminal_engines

  @doc """
  Whether somebody turned this agent off and it still holds its seat. Off is
  intent, whatever the process is doing; a retired agent is retired, not off.
  """
  @spec off?(t()) :: boolean()
  def off?(%__MODULE__{} = agent), do: not is_nil(agent.off_at) and not retired?(agent)

  @doc "Whether this agent was retired: gone for good, seat freed, row kept for history."
  @spec retired?(t()) :: boolean()
  def retired?(%__MODULE__{retired_at: at}), do: not is_nil(at)

  @doc "What a tool that would act on a retired agent answers instead."
  @spec retired_refusal(t()) :: String.t()
  def retired_refusal(%__MODULE__{} = agent) do
    reason = if agent.retired_reason, do: ": #{agent.retired_reason}", else: ""

    "this agent is retired (retired by #{agent.retired_by} at " <>
      "#{DateTime.to_iso8601(agent.retired_at)}#{reason}); it cannot be turned on — " <>
      "start a new agent in its seat instead"
  end

  @doc ~S|The off line check_in and list_agent_work print: "off — turned off by <who> (<when>): <reason>".|
  @spec describe_off(t()) :: String.t()
  def describe_off(%__MODULE__{} = agent),
    do: "off — turned off by #{agent.off_by} (#{when_off(agent)})#{reason_suffix(agent)}"

  @doc "What a tool that would act on an off agent answers instead."
  @spec off_refusal(t()) :: String.t()
  def off_refusal(%__MODULE__{} = agent) do
    "this agent is off (turned off by #{agent.off_by} at #{when_off(agent)}" <>
      "#{reason_suffix(agent)}); turn it on first"
  end

  defp when_off(%__MODULE__{off_at: at}), do: DateTime.to_iso8601(at)

  defp reason_suffix(%__MODULE__{off_reason: reason}) when is_binary(reason), do: ": #{reason}"
  defp reason_suffix(%__MODULE__{}), do: ""

  @doc """
  Add a task to this agent's list.

  The same shape as `Session.add_task/2`: both owners hold the same `Task`.
  `Task.agent_id` is left alone — the list a task is in says who owns it; on a
  session's task that field means the Claude Code sub-agent it was assigned to.
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
  @spec active_task(t()) :: CodeMySpec.Agents.Agent.Task.t() | nil
  def active_task(%__MODULE__{tasks: tasks}) do
    Enum.find(tasks || [], &(&1.status == :active))
  end

  @doc "One of this agent's tasks by id."
  @spec find_task(t(), String.t()) :: CodeMySpec.Agents.Agent.Task.t() | nil
  def find_task(%__MODULE__{tasks: tasks}, task_id) do
    Enum.find(tasks || [], &(&1.id == task_id))
  end

  @doc """
  Drop one of this agent's tasks by id.

  Only for a task moving to another owner (`AssignIssueToWorkingCopy`
  reassigning an issue): the task itself is re-added verbatim, under the
  same id, on the new owner — this just stops the old owner holding it too.
  """
  @spec drop_task(t(), String.t()) :: Ecto.Changeset.t()
  def drop_task(%__MODULE__{} = agent, task_id) do
    remaining = Enum.reject(agent.tasks || [], &(&1.id == task_id))

    agent
    |> change()
    |> put_embed(:tasks, remaining)
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :engine,
      :engine_session_id,
      :transcript_path,
      :git_rewrite_at,
      :current_tool,
      :turn_tool_count,
      :waiting_since,
      :provider,
      :model,
      :working_copy,
      :role,
      :tools,
      :config_dir,
      :os_pid,
      :os_boot_id,
      :status,
      :stopped_reason,
      :off_at,
      :off_by,
      :off_reason,
      :retired_at,
      :retired_by,
      :retired_reason,
      :continuous,
      :turn_started_at,
      :declined_offer,
      :declined_offer_at,
      :declined_offer_count,
      :provider_refusal,
      :provider_refused_at,
      :provider_retry_at,
      :working_copy_id,
      :execution_mode,
      :story_id,
      :epic_id,
      :issue_id,
      :team_free_at,
      :project_id,
      :account_id
    ])
    |> validate_required([
      :engine,
      :provider,
      :working_copy,
      :role,
      :project_id,
      :account_id
    ])
    |> maybe_require_working_copy_id(agent)
    |> foreign_key_constraint(:working_copy_id)
    |> References.check()
    |> foreign_key_constraint(:story_id)
    |> validate_story_holder()
    |> foreign_key_constraint(:epic_id)
    |> foreign_key_constraint(:issue_id)
    |> validate_config_dir_outside_working_copy()
    |> assoc_constraint(:project)
    |> unique_constraint([:project_id, :engine_session_id])
    |> unique_constraint(:project_id, name: :agents_one_detached_product_per_project)
  end

  # Required on creation only: the FK nilifies on checkout delete, and a row
  # left that way must still be writable (a stop, say).
  defp maybe_require_working_copy_id(changeset, %__MODULE__{id: nil}) do
    case {get_field(changeset, :execution_mode), get_field(changeset, :role)} do
      {:detached, role} when role in [:product, :main] ->
        if get_field(changeset, :working_copy_id),
          do: add_error(changeset, :working_copy_id, "must be empty for a detached agent"),
          else: changeset

      {:detached, _} ->
        add_error(changeset, :execution_mode, "is only available for product and main")

      _ ->
        validate_required(changeset, [:working_copy_id])
    end
  end

  defp maybe_require_working_copy_id(changeset, %__MODULE__{}), do: changeset

  # Only a story-scope role (coding, QA) holds a story. Main never does: it
  # guards against the team's work rather than doing it. Product holds an epic.
  defp validate_story_holder(changeset) do
    role = get_field(changeset, :role)

    if is_nil(get_field(changeset, :story_id)) or
         RoleProfile.scope(role) == :story,
       do: changeset,
       else: add_error(changeset, :story_id, "only a coding or QA agent holds a story")
  end

  # A working copy gets committed and pushed, so a credential directory inside
  # it is a leak. Enforced here rather than trusted to every caller.
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
