defmodule CodeMySpec.Repo.Migrations.AnAgentHoldsItsOwnTasks do
  use Ecto.Migration

  @moduledoc """
  Tasks stop needing a session.

  A task was `embeds_many` on `Session`, so it could not exist without one — and
  an agent we run has no session and cannot get one. It fires no hooks, so
  nothing injects a `session_id`; `register_session` is not a tool it carries;
  and its own id was not in its prompt. So an agent could take turns, call
  tools, and never claim a piece of work. It said so itself: *"this session must
  be registered before a task can start, but `register_session` is not available
  in the provided tools."*

  John: *"we shouldn't need a session to create tasks, dude. You should be
  keying the tasks to the agent and then embeds many on there."*

  ## Why a second list rather than one table

  Ownership becomes structural: a task is in exactly one list because it is
  stored in one row, so nothing needs a constraint to say who owns it — and
  `Task.agent_id` becomes redundant on an agent's tasks rather than load-bearing.
  John: "we don't need agent ID ... we don't need the foreign key so don't
  care."

  A `tasks` table is the better end state and is not urgent. What the embedded
  form cannot answer is a question that names no owner — every active task on a
  requirement, or what completed this week — and with ten live agents the
  reporting in front of us ("what is being done now") is a scan of ten short
  lists. The trigger for promoting it is a cross-owner query, not a hunch.

  It also splits the way the two stop paths already do. `Hooks.Stop` serves
  external agents and reads a session's tasks, unchanged; `Agents.StopDecision`
  serves the agents we run and reads the agent's. Nothing has to work out which
  kind it is holding.

  ## No backfill

  Existing tasks belong to sessions and stay there. This adds an empty list to
  every agent, which is what an agent that has never claimed work has anyway.
  """

  def change do
    # `{:array, :map}` — jsonb[], matching how `sessions.tasks` is stored, so
    # one embedded Task schema serves both owners without a second encoding.
    alter table(:agents) do
      add :tasks, {:array, :map}, default: [], null: false
    end
  end
end
