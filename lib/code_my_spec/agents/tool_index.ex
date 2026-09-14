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
      section("Called directly", carried(agent)),
      section("Called from inside `run_script`", scriptable(agent)),
      section("Called from inside `run_browser_script`", Enum.sort(machine_tools || []))
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

    Names only. You already have full schemas for what you carry; `tool_docs`
    gives arguments for anything else. A name missing here is a tool you cannot
    reach — report that rather than working around it.
    """
    |> String.trim()
  end

  defp section(_heading, []), do: nil
  defp section(_heading, nil), do: nil

  defp section(heading, names) do
    "**#{heading}:** " <> Enum.join(names, ", ")
  end

  # What the row says, not what the role says. `ToolSets.for_role/1` is how the
  # list is computed at start; the column is what was actually granted, and an
  # agent that predates scoping has `nil` there meaning "everything".
  defp carried(%Agent{tools: tools}) when is_list(tools), do: Enum.sort(tools)
  defp carried(%Agent{}), do: []

  defp scriptable(%Agent{tools: allowed}) do
    ScriptableTools.__components__()
    |> Catalog.from(fn _tool -> fn _args -> {:error, :index_only} end end, allowed)
    |> Catalog.names()
  rescue
    # An index is a convenience and must never be the reason an agent fails to
    # start. A catalog that cannot be built answers with no section, and the
    # agent is exactly as it was before this existed.
    _ -> []
  end
end
