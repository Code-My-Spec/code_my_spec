defmodule CmsHarness.Agents.Tools.EvaluateTask do
  @moduledoc """
  The fourth of the spine, carried directly. See
  `CmsHarness.Agents.Tools.GetNextRequirement` for why all four are here.

  The one an agent is most likely to skip, and the stop hook nudges it for
  exactly that: *"You stopped with <requirement> still open. Close it yourself
  when it is done — nothing will do it for you."* An agent without this tool
  could read that nudge and have no way to act on it.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "evaluate_task",
    nothing_to: "no task it can close"

  @impl true
  def description do
    """
    Judge your open task against its requirement and close it if it passes.

    Yours to call. Nothing completes a task on your behalf — that judgement is
    the one you are here to make — and a passing evaluation is also what tells
    the other roles on this working copy that work they were waiting on is done.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "Id of the task to evaluate"}
      },
      required: ["task_id"]
    }
  end
end
