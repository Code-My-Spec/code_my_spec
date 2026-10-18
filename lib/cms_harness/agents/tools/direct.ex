defmodule CmsHarness.Agents.Tools.Direct do
  @moduledoc """
  The tools an agent carries because a script may not have them.

  `CodeMode.Catalog` refuses to bind `assign_subagent` to a script, and the
  reason it gives is about scripts: "it spawns background work, and a loop
  around it is a fleet". That is an argument against looping over a spawn, not
  against an agent making one — and until story 963's QA the difference had no
  consequence, because an agent carried six tools and none of them was these.
  It could describe a hand-over in detail and never make one:

      Nothing has been assigned yet: this session has no start_agent or
      assign_subagent tool available. The next step is for a coordinator with
      agent-launch access …

  It was describing itself. So they are carried directly, one call per turn,
  where the model decides each one and the transcript shows it — which is
  exactly what a loop would take away.

  Each is built from the definition the server's launch request carries, and
  forwards to the MCP tool of the same name. The name, description and schema
  are the server's, so the engine's tool cannot disagree with the one every
  other client lists. They used to be a hand-written module each, and a tool
  the server listed with no module here answered `Unknown tool` — `promote` and
  all four of the spine did, each found by an agent that had been told to call
  it.
  """

  alias CmsHarness.Mcp

  @doc "An Alloy tool forwarding to the MCP tool `definition` describes."
  @spec tool(map()) :: Alloy.Tool.Inline.t()
  def tool(%{"name" => name} = definition) do
    Alloy.Tool.inline(
      name: name,
      description: definition["description"],
      input_schema: definition["input_schema"],
      execute: &forward(name, &1, &2),
      # Only a person's turn. `:code_execution` is what `run_script` runs as,
      # and letting these back in through that door would rebuild the loop the
      # exclusion exists to prevent.
      allowed_callers: [:human],
      result_type: :text
    )
  end

  # Pass through what the caller set and nothing else, so a tool that gains an
  # argument on the server gains it here without an edit.
  defp forward(name, input, %{mcp_client: client}) when not is_nil(client),
    do: Mcp.call(client, name, if(is_map(input), do: input, else: %{}))

  defp forward(name, _input, _context) do
    {:error,
     "This agent has no session with its project's server, so `#{name}` cannot reach it. " <>
       "Check the harness is connected."}
  end
end
