defmodule CmsHarness.Agents.Tools.StartAgent do
  @moduledoc """
  Put another agent on a working copy.

  The act story 963 is about — "the main agent hands over rather than
  designing". Carried directly rather than reachable from a script, for the
  reason in `CmsHarness.Agents.Tools.Direct`.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "start_agent",
    nothing_to: "nowhere to start an agent"

  @impl true
  def description do
    """
    Start another agent on a working copy and return its id.

    Use this to hand work over rather than doing it yourself: a story that
    needs building goes to an agent started for it, and you report on what it
    does. `message_agent` (through `run_script`) talks to it afterwards, and
    `stop_agent` ends it.

    Starting is not free — it spends the account's subscription for as long as
    the agent runs. Start one when somebody asked for the work, not to see
    what happens.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        provider: %{
          type: "string",
          description: "Which connected provider to spend, e.g. openai-codex, anthropic, zai"
        },
        role: %{
          type: "string",
          description: "main, product, coding or qa. Defaults to main."
        },
        engine: %{type: "string", description: "pi (default) or claude_code"},
        working_copy: %{
          type: "string",
          description: "Root to run in. Defaults to your own, which already holds you."
        }
      },
      required: ["provider"]
    }
  end
end
