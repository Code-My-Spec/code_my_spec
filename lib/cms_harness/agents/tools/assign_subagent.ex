defmodule CmsHarness.Agents.Tools.AssignSubagent do
  @moduledoc """
  Give a task to an agent that is already running.

  The other half of handing over. `start_agent` makes somebody to hand to; this
  is the handing, and it is the one that keeps the context a running agent has
  already built instead of throwing it away for a fresh start.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "assign_subagent",
    nothing_to: "no session holding the task"

  @impl true
  def description do
    """
    Assign a task to a sub-agent that is already running.

    Prefer this to starting another one when a suitable agent exists: it keeps
    what that agent has already worked out. `list_session_subagents` (through
    `run_script`) says who is available.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        agent_id: %{type: "string", description: "Registered sub-agent id"},
        task_id: %{type: "string", description: "Task to give it"}
      },
      required: ["agent_id", "task_id"]
    }
  end
end
