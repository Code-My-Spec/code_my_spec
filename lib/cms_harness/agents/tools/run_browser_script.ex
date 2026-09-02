defmodule CmsHarness.Agents.Tools.RunBrowserScript do
  @moduledoc """
  The browser's half of code mode, as its own tool.

  `run_script` reaches this project's tools; this one reaches the browser on the
  machine the agent is running on. They were one tool until the deadlines made
  the split necessary — see the server's
  `CodeMySpec.McpServers.CodeMode.Tools.RunBrowserScript` for the argument.

  What the agent pays for the browser is still one schema, which is the whole of
  story 1038: eighty-five vibium tools arrive as this, and `tool_docs` names them.

  The script runs on the server, like `run_script`'s, and the server pushes each
  browser call back down to this machine. A long way round for a browser that is
  sitting on the same box, and the reason is authority: the catalog is built
  from the agent's own row, so a script cannot call a tool the agent was not
  given by taking a shortcut past the server that knows which ones those are.
  """

  @behaviour Alloy.Tool

  alias CmsHarness.Mcp

  # Same ceiling `run_script` has. A page's HTML arrives larger than everything
  # the agent was going to think about, and the saving two tools were carried
  # for is gone in one reply.
  @max_result_chars 24_000

  # The deadline the server defaults to, restated here because this side has to
  # wait at least as long as the far side might take. A client that gives up
  # first turns an answer into a timeout with no way to tell them apart.
  @default_timeout_ms 60_000

  # What the transport is allowed on top: the server's own sandbox stops at
  # `timeout` and needs a moment to say so. Without this the client would give
  # up at the same instant, and a script that timed out cleanly would arrive as
  # a dead connection.
  @transport_margin_ms 5_000

  @impl true
  def name, do: "run_browser_script"

  @impl true
  def description do
    """
    Run a Lua script against the browser on this machine.

        browser_navigate({ url = "http://127.0.0.1:4000/app" })
        browser_wait_for_text({ text = "Overview", timeout = 20000 })
        return browser_get_url({})

    Separate from `run_script` because browser tools wait — for a page, an
    element, a redirect — where the project's tools answer immediately. Pass
    `timeout` in milliseconds for the whole script when a minute is not enough.

    `tool_docs` lists what this machine's browser offers.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        script: %{type: "string", description: "Lua source. Use `return` to answer."},
        timeout: %{
          type: "integer",
          description: "Milliseconds for the whole script. Defaults to 60000."
        }
      },
      required: ["script"]
    }
  end

  @impl true
  def execute(%{"script" => script} = input, context) do
    with {:ok, client} <- session(context) do
      timeout = timeout(input)

      client
      |> Mcp.call("run_browser_script", arguments(script, timeout, context),
        timeout: timeout + @transport_margin_ms
      )
      |> answer()
    end
  end

  def execute(_input, _context), do: {:error, "run_browser_script needs a `script`."}

  @impl true
  def allowed_callers, do: [:human, :code_execution]

  @impl true
  def result_type, do: :text

  defp timeout(%{"timeout" => ms}) when is_integer(ms) and ms > 0, do: ms
  defp timeout(_input), do: @default_timeout_ms

  # The agent names itself and the server reads what it carries off its own row,
  # the same rule `run_script` follows. A machine that sent its own list would
  # be declaring its own scope.
  defp arguments(script, timeout, %{agent_id: agent_id}) when is_binary(agent_id),
    do: %{"script" => script, "timeout" => timeout, "agent_id" => agent_id}

  defp arguments(script, timeout, _context),
    do: %{"script" => script, "timeout" => timeout}

  defp session(%{mcp_client: client}) when not is_nil(client), do: {:ok, client}

  defp session(_context) do
    {:error,
     "This agent has no session with its project's server, so nothing can be " <>
       "called. The machine could not authenticate — check the harness is connected."}
  end

  defp answer({:ok, text}), do: {:ok, truncate(text)}
  defp answer({:error, reason}) when is_binary(reason), do: {:error, truncate(reason)}
  defp answer({:error, reason}), do: {:error, truncate(inspect(reason))}

  defp truncate(text) when byte_size(text) <= @max_result_chars, do: text

  defp truncate(text) do
    note = "\n\n[truncated — the answer was longer than #{@max_result_chars} characters]"
    kept = @max_result_chars - byte_size(note)

    binary_part(text, 0, kept) <> note
  end
end
