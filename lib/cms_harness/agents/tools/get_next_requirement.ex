defmodule CmsHarness.Agents.Tools.GetNextRequirement do
  @moduledoc """
  The first of the four the loop walks, carried directly.

  `LocalServer` calls these the spine and its own comment states the rule they
  have to satisfy: *"a tool excluded from scripts and absent from here would be
  reachable by no route at all."* That is exactly what happened to an Alloy
  agent. `CodeMode.Catalog` excludes all four from `run_script` — and the reason
  it gives is "it is one of the four tools you already have directly — call it
  as a tool" — while `Engine.tools/1` carried ten modules and none of them was
  these.

  So the exclusion's reason was true of a Claude Code agent, which reaches them
  over MCP, and false of ours. John's main agent, 2026-09-06: *"I can't call
  get_next_requirement in this session: it isn't available in the active tool
  catalog, despite being listed in the project guide."* It was right, and it had
  no way through — the door it was sent to was the one that had been shut.

  Not a loop's worth of calls either way: one per turn, which is what the
  exclusion was protecting and what carrying it directly preserves.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "get_next_requirement",
    nothing_to: "no graph it can read"

  @impl true
  def description do
    """
    The next actionable requirement for this project: unsatisfied, every
    prerequisite met, and something can be done about it.

    Read-only. Call `start_task` with what it returns to begin the work — this
    only tells you what is next, it does not claim it.
    """
  end

  @impl true
  def input_schema do
    %{type: "object", properties: %{}, required: []}
  end
end
