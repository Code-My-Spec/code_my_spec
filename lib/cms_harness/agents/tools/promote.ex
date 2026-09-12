defmodule CmsHarness.Agents.Tools.Promote do
  @moduledoc """
  Put this copy's finished work on the checkout the application runs from.

  Carried directly for the reason the other spawns are: a promotion merges,
  sweeps analyzers and restarts an application, and `CodeMode.Catalog` will not
  bind that to a script — so without this module it is reachable by no route at
  all from an agent we run.

  Which is exactly what happened. `code_on_running_copy` is a coding
  requirement, the orchestrator hands it to the coding role, and the agent found
  `promote` documented by `tool_docs`, granted to its role in `ToolSets`, listed
  on `LocalServer` — and still got `Unknown tool: promote`, because an Alloy
  agent's tools are this module list and nothing here named it. The agent
  reported the only thing visible from inside, "the grant didn't land in this
  session's live tool set", twice, and was right both times about the symptom
  and wrong about the cause.

  Two surfaces, and they have to be changed together: `ToolSets` governs what a
  Claude Code agent reaches over MCP, `Engine.tools/1` governs what an agent in
  our own BEAM carries. A tool added to one and not the other exists for half
  the fleet.

  `promote_sync` is deliberately not carried. An agent here has an identity on
  its connection and a conversation to be told in, so this returns at once and
  the outcome arrives as a message; the synchronous door is for callers with
  neither, and holding a tool call open for the length of a build is what it
  would buy.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "promote",
    nothing_to: "no running copy it can promote to"

  @impl true
  def description do
    """
    Put your finished work on the checkout the application runs from, so QA
    tests the code you wrote.

    Returns as soon as the promotion starts. Do not wait for it and do not poll
    — the outcome is delivered to you as a message when it lands, because the
    analyzer sweep it waits on takes minutes.

    Takes no arguments. The target is the project's designated main working
    copy: there is one place work goes, so there is no branch to name.

    Commit first. It refuses a copy with uncommitted work, by design. Untracked
    files do not block it — they are listed in the result so you can see
    anything you meant to `git add` and did not.
    """
  end

  @impl true
  def input_schema do
    %{type: "object", properties: %{}, required: []}
  end
end
