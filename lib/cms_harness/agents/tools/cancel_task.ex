defmodule CmsHarness.Agents.Tools.CancelTask do
  @moduledoc """
  The disposition an agent had no way to make.

  The open-task menu offers four endings — complete, ask, tap out, cancel — and
  an agent carried tools for three of them. `cancel_task` existed only as a
  server-side MCP tool for Claude Code sessions, so the menu named it to every
  internal agent and every internal agent got `Unknown tool`. Caught by
  `the_menu_only_names_tools_the_reader_has_test`, which exists for exactly this
  class: a directive is a promise that the reader can act on it.

  Cancelling ends this recorded attempt and nothing else. The graph requirement
  stays available to start later — an attempt abandoned is not a requirement
  withdrawn, which is why this is a disposition rather than a failure.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "cancel_task",
    nothing_to: "no task it can cancel"

  @impl true
  def description do
    """
    Abandon your open task without completing it.

    For an attempt that is not going to finish — the approach was wrong, or the
    work turned out to belong somewhere else. It closes only this attempt: the
    requirement goes back on the graph and anyone, including you, can start it
    again. Use `evaluate_task` when the work is actually done.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "Id of the task to cancel"}
      },
      required: ["task_id"]
    }
  end
end
