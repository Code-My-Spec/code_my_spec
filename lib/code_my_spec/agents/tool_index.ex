defmodule CodeMySpec.Agents.ToolIndex do
  @moduledoc """
  Every tool this agent can reach, by name, and nothing else.

  Names only — no descriptions, no schemas. An agent already gets full schemas
  for the tools it carries, and `tool_docs` answers for the rest on demand. What
  it had no way to learn was that the rest exist.

  ## What that cost, measured today

  A QA agent was told in its own priming to check open questions with
  `list_user_questions`, called it, and got "Unknown tool". It reported the gap
  rather than working around it, which was right, and stopped. The tool is real
  — it is simply not one a QA agent carries — and nothing it could read said so.

  An earlier QA agent spent a session concluding that story 895's epic tools
  were "not reachable from this box's local MCP surface". It had probed
  `tools/list` on the harness endpoint, which answers with carried tools only.
  `create_epic`, `assign_story_to_epic` and `assign_epic_to_working_copy` were
  all reachable the whole time through `run_script`, which that same session
  listed among its own tools. It filed an issue saying the story could not be
  QA'd on this box. A later agent did it in one turn.

  Both are the same absence: the agent could see what it holds and could not see
  what it can reach. A name is enough to close that — an agent that knows
  `assign_epic_to_working_copy` exists will find its arguments.

  ## Why names are cheap enough to send every turn

  Roughly two hundred names is a couple of kilobytes. The schemas for the same
  tools are around thirty kilobytes for the browser's alone, which is the reason
  they are behind `tool_docs` in the first place — see `CmsHarness.Browser`. A
  wasted turn costs more than the index does, and the failures above cost turns
  and sessions.

  ## Three groups, because reaching them differs

  Carried tools are called directly. Scriptable tools are called from inside
  `run_script`. Browser tools are called from inside `run_browser_script` and
  belong to the machine rather than to us. An agent that knows a name but calls
  it the wrong way is no better off, so the grouping is the instruction.
  """

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools

  @doc """
  The index for this agent, or `nil` when there is nothing to say.

  `nil` rather than an empty heading, for the reason `RoleBrief.for/1` gives:
  an agent told something vague is worse off than one told nothing.

  `machine_tools` comes from the working copy the agent runs on, so a machine
  with no browser contributes no section rather than an empty one — those are
  different states and only one of them is a fault. See `CmsHarness.Browser`.
  """
  @spec for(Agent.t(), [String.t()]) :: String.t() | nil
  def for(%Agent{} = agent, machine_tools \\ []) do
    [
      section(direct_heading(), carried(agent)),
      section(scriptable_heading(), scriptable(agent)),
      section(browser_heading(), Enum.sort(machine_tools || []))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sections -> Enum.join([preamble() | sections], "\n\n")
    end
  end

  defp preamble do
    """
    ## Tools you can reach

    Names only. `tool_docs` gives arguments for any of them.

    **The three lists are reached three different ways, and using the wrong one
    fails.** A name below is a tool you can reach; how you reach it depends on
    which list it is in. A name *absent* from all three is a tool you cannot
    reach at all — report that rather than working around it.
    """
    |> String.trim()
  end

  defp section(_heading, []), do: nil
  defp section(_heading, nil), do: nil

  defp section(heading, names), do: "**#{heading}:** " <> Enum.join(names, ", ")

  # Headings name the route, not the wire format.
  #
  # They say which of three ways a name is reached and stop there. *How* a call
  # is physically made is the provider's business — on `claude-code` it is a
  # `tool_calls` entry in a JSON object, on an engine with native tool calling
  # it is nothing of the sort — so the shape, and the worked example of the
  # nested form, live in `ProviderBrief` where they can differ per engine.
  defp direct_heading, do: "Called directly"

  defp scriptable_heading, do: "Called from inside `run_script`"

  defp browser_heading, do: "Called from inside `run_browser_script`"

  # What the direct server exposes, which is the same for every agent.
  #
  # Not the `tools` column. That column governs what a *script* may call and its
  # names are `ScriptableTools` components — `create_issue`, `list_stories` and
  # the rest of the domain; none of them has ever been reachable directly.
  # Listing them under "Called directly" told the agent to call something the
  # direct server does not expose, and agents did exactly that: 3543 lost two
  # runs in ten to one calling `create_issue`, getting `Unknown tool`, and then
  # correctly refusing to route around a tool it had been told was broken.
  #
  # The `nil` branch failed the other way round. An agent whose column was unset
  # was told it carried nothing at all, so the index contradicted the
  # `available_tools` it was sent — the likeliest source of agents reporting
  # `get_next_requirement` as "No such tool available" while it sat in the list.
  #
  # The direct surface is the loop: `get_next_requirement`, `start_task`,
  # `evaluate_task`, `tap_out`, `run_script`, `tool_docs` and their neighbours.
  # It is not scoped by role, so neither is this.
  defp carried(%Agent{}) do
    LocalServer.__components__() |> Enum.map(& &1.name) |> Enum.sort()
  end

  # `Catalog.from/3` maps, rejects and filters a list into a map, and
  # `Catalog.names/1` sorts its keys — both total over a well-formed component
  # list, which `__components__/0` is by construction. This was wrapped in a
  # rescue answering `[]`, on the reasoning that an index is a convenience and
  # must never stop an agent starting. That guarded nothing reachable and hid
  # the one thing worth seeing: a malformed registration, which should be loud.
  defp scriptable(%Agent{tools: allowed}) do
    ScriptableTools.__components__()
    |> Catalog.from(fn _tool -> fn _args -> {:error, :index_only} end end, allowed)
    |> Catalog.names()
  end
end
