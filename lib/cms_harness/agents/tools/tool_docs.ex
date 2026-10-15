defmodule CmsHarness.Agents.Tools.ToolDocs do
  @moduledoc """
  The other of the two: what a script may call, and what each one takes.

  The reason two tools beat ninety-eight is not that the ninety-eight are
  unavailable — they are all reachable through `run_script` — it is that their
  schemas are read on every turn to answer a question the agent asks once. This
  is that question, asked once, when it has decided which tool it wants.

  Names by default and arguments on request, for the same reason. A list of
  every tool's schema is the catalogue again in one string.
  """

  @behaviour Alloy.Tool

  alias CmsHarness.Mcp

  @impl true
  def name, do: "tool_docs"

  @impl true
  def description do
    """
    What this project's tools are called, and what one takes.

    With no arguments: every tool name with a one-line summary. With `name`
    or `names`: the full arguments for those tools, which is what you need
    before calling one from `run_script`. With `search`: tools whose name or
    summary matches, when you know what you want to do but not what it is
    called.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "One tool to describe in full. Omit for the list of names."
        },
        names: %{
          type: "array",
          items: %{type: "string"},
          description: "Several tools to describe in full. Omit for the list of names."
        },
        search: %{
          type: "string",
          description: "Search tool names and summaries. Ignored when name/names is given."
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    with {:ok, client} <- session(context) do
      Mcp.call(client, "tool_docs", arguments(input))
    end
  end

  @impl true
  def allowed_callers, do: [:human, :code_execution]

  @impl true
  def result_type, do: :text

  # Pass `name`/`names` through whatever shape the caller gave them, rather
  # than recognizing only a well-formed `names` list and silently sending no
  # arguments at all otherwise (253b3b93/328ce14f: a singular `name` -- the
  # form the real tool's own error messages tell a caller to use -- or a
  # `names` that was not already a non-empty list both fell through to this
  # function's catch-all, and a caller asking about one tool got the full
  # catalog back with no sign its argument was ever dropped). The real
  # `tool_docs` tool already validates and refuses a malformed value by
  # name; forwarding it is what lets that refusal reach the caller instead
  # of being silently swallowed here first.
  defp arguments(input) do
    %{}
    |> maybe_put("name", Map.get(input, "name"))
    |> maybe_put("names", Map.get(input, "names"))
    |> maybe_put("search", Map.get(input, "search"))
  end

  defp maybe_put(args, _key, nil), do: args
  defp maybe_put(args, key, value), do: Map.put(args, key, value)

  defp session(%{mcp_client: client}) when not is_nil(client), do: {:ok, client}

  defp session(_context) do
    {:error,
     "This agent has no session with its project's server, so there is nothing " <>
       "to look up. Check the harness is connected."}
  end
end
