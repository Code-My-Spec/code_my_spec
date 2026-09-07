defmodule CodeMySpecTest.InVmMcpTransport do
  @moduledoc """
  The session, without the socket.

  `CodeMySpecWeb.Endpoint` runs `server: false` in test, so nothing in a spex
  can make the HTTP hop the real transport makes. This dispatches to the same
  server-side tools that hop would have reached, in this VM.

  What is stood in for is the wire and only the wire. The tool the agent
  carries, the truncation, the catalog, the scoping and the Lua all run for
  real, and the answer a criterion asserts on is the answer the server really
  gave. That is the same bargain `config/test.exs` already makes a dozen times
  over with `Req.Test`: pin the transport, run everything else.

  ## Why it lives in test support rather than beside the real transport

  `Project.Transport.Test` sits in `lib/` and this one cannot: standing in for
  the wire between the harness and the server means touching both sides, and
  `CmsHarness` is not allowed to reference `CodeMySpec.McpServers`. The closer
  precedent is `CodeMySpecTest.InProcessAgentTransport`, which is the same
  shape for the same reason and already lives here.

  ## Whose scope

  From the test process, the way `Project.Transport.Test` takes its owner —
  `Application.get_env(:code_my_spec, :harness_mcp_scope)`. That is the agent's
  own scope, which is what makes the isolation criterion real rather than
  circular: the script runs as the agent, and a story belonging to another
  project is refused by the tool's own scoping rather than by anything here.
  """

  @behaviour CmsHarness.Mcp.Transport

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode
  alias CodeMySpec.McpServers.CodeMode.Tools.RunBrowserScript
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs

  @impl true
  def connect(_name, opts) do
    case Keyword.get(opts, :command) do
      # A subprocess this VM is not going to start. What a browser on this
      # machine offers is set by the test the way the scope is, so a criterion
      # about reaching one does not need Chrome.
      nil -> {:ok, {__MODULE__, Keyword.get(opts, :headers, %{})}}
      _command -> {:ok, {__MODULE__, :browser}}
    end
  end

  @impl true
  def call({__MODULE__, _headers}, "run_script", %{"script" => script} = arguments) do
    dispatch(RunScript, script_params(script, arguments))
  end

  def call({__MODULE__, _headers}, "run_browser_script", %{"script" => script} = arguments) do
    dispatch(RunBrowserScript, browser_params(script, arguments))
  end

  def call({__MODULE__, _headers}, "tool_docs", arguments) do
    dispatch(ToolDocs, docs_params(arguments))
  end

  def call({__MODULE__, :browser}, tool, arguments) do
    case tool in browser_tools() do
      true -> {:ok, "#{tool} ran with #{inspect(arguments)}"}
      false -> {:error, "This machine's browser has no tool called #{inspect(tool)}."}
    end
  end

  def call({__MODULE__, _headers}, tool, _arguments) do
    {:error, "This server has no tool called #{inspect(tool)}."}
  end

  # The deadline is carried, not honoured. Nothing here waits, and a stand-in
  # that slept for the caller's minute would make every criterion about the
  # browser cost one. Where the derived number is checked is
  # `CodeMySpec.McpServers.CodeModeTest`, off the catalog entry that states it.
  @impl true
  def call(client, tool, arguments, _opts), do: call(client, tool, arguments)

  @impl true
  def list_tools({__MODULE__, :browser}) do
    # The shape vibium really answers with, keys and all: `inputSchema` camel,
    # a description, a required list. A stand-in that returned a tidier shape
    # would let a bug in the reading of the real one through.
    {:ok,
     Enum.map(browser_tools(), fn name ->
       %{
         "name" => name,
         "description" => "Stand-in for #{name} on this machine's browser.",
         "inputSchema" => %{
           "type" => "object",
           "properties" => %{
             "selector" => %{"type" => "string", "description" => "What to act on"}
           },
           "required" => ["selector"]
         }
       }
     end)}
  end

  def list_tools({__MODULE__, _headers} = client) do
    with {:ok, names} <- list_tool_names(client) do
      {:ok, Enum.map(names, &%{"name" => &1, "description" => "", "inputSchema" => %{}})}
    end
  end

  @impl true
  def list_tool_names({__MODULE__, :browser}), do: {:ok, browser_tools()}

  # Through the catalog rather than at `ScriptableTools`: which tools exist is
  # the MCP layer's knowledge, and `CmsHarness` is not allowed to reach past it
  # to the registry behind it.
  def list_tool_names({__MODULE__, _headers}) do
    case scope() do
      nil -> {:ok, []}
      scope -> {:ok, scope |> CodeMode.catalog() |> Map.keys()}
    end
  end

  defp script_params(script, %{"agent_id" => id}) when is_binary(id),
    do: %{script: script, agent_id: id}

  defp script_params(script, _arguments), do: %{script: script}

  defp browser_params(script, arguments) do
    case Map.get(arguments, "timeout") do
      ms when is_integer(ms) -> Map.put(script_params(script, arguments), :timeout, ms)
      _ -> script_params(script, arguments)
    end
  end

  defp docs_params(%{"names" => names}) when is_list(names), do: %{names: names}
  defp docs_params(_arguments), do: %{}

  defp dispatch(tool, params) do
    case scope() do
      nil ->
        {:error,
         "No scope is configured for the local MCP transport. Set " <>
           "`:harness_mcp_scope` to the scope this agent runs as."}

      scope ->
        {:reply, response, _frame} =
          tool.execute(params, %Frame{assigns: %{current_scope: scope}})

        answer(response)
    end
  end

  # An `isError` response is the tool refusing, and a refusal has to arrive as
  # one — `run_script` reports a refused call by returning an error, and a
  # criterion asserting on the refusal would otherwise assert on a success.
  defp answer(%{isError: true} = response), do: {:error, text(response)}
  defp answer(response), do: {:ok, text(response)}

  defp text(%{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp text(other), do: inspect(other)

  defp scope, do: Application.get_env(:code_my_spec, :harness_mcp_scope)

  defp browser_tools, do: Application.get_env(:code_my_spec, :harness_browser_tools, [])
end
