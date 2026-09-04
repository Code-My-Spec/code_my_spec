defmodule CmsHarness.Agents.Tools.RunScript do
  @moduledoc """
  One of the two tools an agent carries instead of ninety-eight.

  The script runs on the server, beside the data. That is the point rather than
  an implementation detail: a loop calling ten tools the ordinary way is ten
  model turns and ten waits on the machine, and here it is one call that comes
  back with ten answers.

  The session is the agent's own — `CmsHarness.Mcp.connect/3` holds one per
  agent — so a script acts with exactly the authority of the agent that ran it.
  Scope is not a thing this passes; it is a thing the token already is.
  """

  @behaviour Alloy.Tool

  alias CmsHarness.Mcp

  # One number, defined where both callers can reach it. This tool cut at
  # 24,000 and said so; the server tool it calls through did not cut at all,
  # and that is the path every Claude Code session reaches over the plugin's
  # MCP mount — so the consumer with the tighter context window was the one
  # with no cap (b9632bba). Two implementations of one rule is how they came
  # to disagree.
  @max_result_chars CodeMySpec.CodeMode.max_answer_bytes()

  @impl true
  def name, do: "run_script"

  @impl true
  def description do
    """
    Run a Lua script against this project's tools and return what it returns.

    Every tool the server exposes is callable as a Lua function taking one
    table: `local s = get_story({ story_id = "970" })`. A tool that cannot
    answer returns nil and an error table.

    Prefer this to asking for one thing at a time — a loop, a filter and a
    summary in one script cost one call, where the same work as separate tool
    calls costs one turn each. Use `tool_docs` to look up what a tool takes.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        script: %{type: "string", description: "Lua source. Use `return` to answer."}
      },
      required: ["script"]
    }
  end

  @impl true
  def execute(%{"script" => script}, context) do
    with {:ok, client} <- session(context) do
      client
      |> Mcp.call("run_script", arguments(script, context))
      |> answer()
    end
  end

  def execute(_input, _context), do: {:error, "run_script needs a `script`."}

  @impl true
  def allowed_callers, do: [:human, :code_execution]

  @impl true
  def result_type, do: :text

  @doc "What a single answer may cost the turn. Public so a spec can ask."
  @impl true
  @spec max_result_chars() :: pos_integer()
  def max_result_chars, do: @max_result_chars

  # The agent names itself, and the server reads which tools that agent carries
  # off its own row. Sending the list from here would let the machine declare
  # its own scope.
  defp arguments(script, %{agent_id: agent_id}) when is_binary(agent_id),
    do: %{"script" => script, "agent_id" => agent_id}

  defp arguments(script, _context), do: %{"script" => script}

  defp session(%{mcp_client: client}) when not is_nil(client), do: {:ok, client}

  defp session(_context) do
    {:error,
     "This agent has no session with its project's server, so nothing can be " <>
       "called. The machine could not authenticate — check the harness is connected."}
  end

  defp answer({:ok, text}), do: {:ok, truncate(text)}
  defp answer({:error, reason}) when is_binary(reason), do: {:error, truncate(reason)}
  defp answer({:error, reason}), do: {:error, truncate(inspect(reason))}

  # Cut, and said so. Cutting silently is worse than not cutting: the agent
  # reasons about a fragment as though it were the whole answer, and nothing in
  # the transcript says otherwise.
  #
  # Delegated so there is one implementation as well as one number — this one
  # split a binary on a byte boundary, which can land inside a multi-byte
  # character and produce a reply that fails to encode.
  defp truncate(text), do: CodeMySpec.CodeMode.cap(text)
end
