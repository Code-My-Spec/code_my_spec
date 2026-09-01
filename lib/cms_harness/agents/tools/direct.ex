defmodule CmsHarness.Agents.Tools.Direct do
  @moduledoc """
  The plumbing under the tools an agent carries because a script may not have
  them.

  `CodeMode.Catalog` refuses to bind `start_agent`, `stop_agent` and
  `assign_subagent` to a script, and the reason it gives is about scripts: "it
  spawns background work, and a loop around it is a fleet". That is an argument
  against looping over a spawn, not against an agent making one — and until
  story 963's QA the difference had no consequence, because an agent carried six
  tools and none of them was these. It could describe a hand-over in detail and
  never make one:

      Nothing has been assigned yet: this session has no start_agent or
      assign_subagent tool available. The next step is for a coordinator with
      agent-launch access …

  It was describing itself. So they are carried directly, one call per turn,
  where the model decides each one and the transcript shows it — which is
  exactly what a loop would take away.

  Everything here is the part that would be copied three times: the session, the
  forward, and the refusal when a machine cannot reach its server. What each
  tool supplies is its name, its sentence, and its schema.
  """

  @doc """
  Define an Alloy tool that forwards to one MCP tool by name.

  `:name` is the MCP tool's name and the Alloy tool's; they are the same tool
  seen from two sides, and giving them different names would make the agent's
  transcript disagree with the server's log about what was called.
  """
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    nothing_to = Keyword.fetch!(opts, :nothing_to)

    quote do
      @behaviour Alloy.Tool

      alias CmsHarness.Mcp

      @impl true
      def name, do: unquote(name)

      @impl true
      def execute(input, context) do
        with {:ok, client} <- session(context) do
          Mcp.call(client, unquote(name), arguments(input))
        end
      end

      # Only a person's turn. `:code_execution` is what `run_script` runs as,
      # and letting these back in through that door would rebuild the loop the
      # exclusion exists to prevent.
      @impl true
      def allowed_callers, do: [:human]

      @impl true
      def result_type, do: :text

      # Pass through what the caller set and nothing else, so a tool that gains
      # an argument on the server gains it here without an edit.
      defp arguments(input) when is_map(input), do: input
      defp arguments(_input), do: %{}

      defp session(%{mcp_client: client}) when not is_nil(client), do: {:ok, client}

      defp session(_context) do
        {:error,
         "This agent has no session with its project's server, so there is " <>
           unquote(nothing_to) <> ". Check the harness is connected."}
      end

      defoverridable arguments: 1
    end
  end
end
