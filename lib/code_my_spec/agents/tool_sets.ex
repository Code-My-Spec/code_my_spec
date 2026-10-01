defmodule CodeMySpec.Agents.ToolSets do
  @moduledoc """
  Which tools an agent may call, as a list.

  Story 982. The obvious shape was to scope by role — ask the agent's type at
  call time and decide from it — and John's call was the other one: the agent
  carries an explicit list, and the role only chooses which list it starts with.

  The difference shows up the first time somebody wants an exception. A QA agent
  that needs one extra tool for one project is a new role under the implicit
  scheme, or a `case` inside the check; under this one it is a different list on
  one row. It also makes the answer readable: "what may this agent call" is a
  column, not a function of a column and a table somewhere else.

  The lists themselves live on each role's `RoleProfile`, with the reasoning
  behind every grant. This module is the row's view of them.
  """

  alias CodeMySpec.Agents.RoleProfile

  @doc """
  The tools an agent of this type starts with, or `nil` for every tool there is.

  `:main`'s profile says `:all`, and on the row that is `nil` rather than a
  list. Enumerating "everything" into a row would be a copy of the catalogue
  that goes stale the day a tool is added — the same argument this column's own
  migration makes for not backfilling one. A stale list would read as a scoping
  decision somebody made.

  `nil` already means "no restriction" everywhere it is read, so main shares a
  meaning with the rows that predate scoping.

  Which tools exist at all is the MCP layer's knowledge and stays there — this
  context is not allowed to ask, and should not want to.
  """
  @spec for_role(atom()) :: [String.t()] | nil
  def for_role(role) do
    case RoleProfile.tools(role) do
      :all -> nil
      granted -> granted
    end
  end
end
