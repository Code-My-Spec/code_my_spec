defmodule CodeMySpec.TaskOwner do
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Repo,
      CodeMySpec.Sessions,
      CodeMySpec.Users
    ],
    exports: :all

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @moduledoc """
  The two things that can hold a task, behind one set of calls.

  A task used to be `embeds_many` on `Session` and nothing else, so it could not
  exist without one — and an agent we run has no session and no way to get one.
  It fires no hooks, so nothing injects a `session_id`; `register_session` is
  not a tool it carries; and its own id was not in its prompt. So it could take
  turns, call tools, and never claim a piece of work. It said so itself: *"this
  session must be registered before a task can start, but `register_session` is
  not available in the provided tools."*

  John: *"we shouldn't need a session to create tasks, dude. You should be
  keying the tasks to the agent."*

  So an `Agent` holds its own, and this is the seam that keeps that from
  becoming two of everything. `Hooks.Stop` serves external agents and passes a
  `Session`; `Agents.StopDecision` serves the ones we run and passes an `Agent`;
  neither knows about the other's storage.

  ## Ownership is the list, not a field

  A task is in exactly one of them because it is stored in one row, so nothing
  needs a constraint to say who owns it, and `Task.agent_id` stays what it
  always was — the Claude Code sub-agent a *session's* task was assigned to,
  a question that does not arise for an agent we run because we do not spawn
  sub-agents.

  ## Why not a table yet

  Because nothing yet asks a question that names no owner. "What is every agent
  doing" names them — ten agents, ten short lists. What the embedded form cannot
  do is *cross-owner* work: every active task on a requirement, or what
  completed this week, both of which mean scanning jsonb across every row. That
  is the trigger to promote it, and when it comes this module is where the
  change lands rather than in fifteen call sites.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.Task
  alias CodeMySpec.Users.Scope

  @type t :: Session.t() | Agent.t()

  @doc "Every task this owner holds."
  @spec tasks(t()) :: [Task.t()]
  def tasks(%Session{tasks: tasks}), do: tasks || []
  def tasks(%Agent{tasks: tasks}), do: tasks || []

  @doc "The task this owner is working, if any."
  @spec active_task(t()) :: Task.t() | nil
  def active_task(owner), do: Enum.find(tasks(owner), &(&1.status == :active))

  @doc "One task by id."
  @spec find_task(t(), String.t()) :: Task.t() | nil
  def find_task(owner, task_id), do: Enum.find(tasks(owner), &(&1.id == task_id))

  @doc """
  Add a task and return the owner with it.

  `agent_id` is not set for an agent owner and that is deliberate: the list says
  whose it is, and a field repeating that is one more thing that can disagree
  with the row holding it.
  """
  @spec add_task(Scope.t(), t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def add_task(%Scope{}, %Session{} = session, attrs) do
    session |> Session.add_task(attrs) |> Repo.update()
  end

  def add_task(%Scope{}, %Agent{} = agent, attrs) do
    agent |> Agent.add_task(Map.delete(attrs, :agent_id)) |> Repo.update()
  end

  @doc "Mark a task active, and note which agent is on it where that matters."
  @spec activate_task(Scope.t(), t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def activate_task(scope, owner, task_id, agent_id \\ nil)

  def activate_task(%Scope{}, %Session{} = session, task_id, agent_id) do
    updates =
      %{status: :active, started_at: now()}
      |> maybe_put_agent(agent_id)

    session |> Session.update_task(task_id, updates) |> Repo.update()
  end

  def activate_task(%Scope{}, %Agent{} = agent, task_id, _agent_id) do
    agent
    |> Agent.update_task(task_id, %{status: :active, started_at: now()})
    |> Repo.update()
  end

  @doc "Close a task out."
  @spec complete_task(Scope.t(), t(), String.t(), atom()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def complete_task(scope, owner, task_id, result \\ :completed)

  def complete_task(%Scope{}, %Session{} = session, task_id, result) do
    session
    |> Session.update_task(task_id, %{status: result, completed_at: now()})
    |> Repo.update()
  end

  def complete_task(%Scope{}, %Agent{} = agent, task_id, result) do
    agent
    |> Agent.update_task(task_id, %{status: result, completed_at: now()})
    |> Repo.update()
  end

  defp maybe_put_agent(updates, nil), do: updates
  defp maybe_put_agent(updates, agent_id), do: Map.put(updates, :agent_id, agent_id)

  defp now, do: DateTime.utc_now()
end
