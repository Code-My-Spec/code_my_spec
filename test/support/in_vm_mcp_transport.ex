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
  alias CodeMySpec.McpServers.LocalServer

  # Nothing to close: this transport dispatches in-process and holds no client.
  @impl true
  def disconnect(_client), do: :ok

  # `agent_id` is kept because it is what the connection carries in production:
  # `CmsHarness.Mcp.connect/3` passes it so the server knows which agent is
  # calling without the model being told its own id. Dropping it here meant
  # every task tool an in-process agent called answered "no session_id and no
  # agent id on this call, so there is no owner to find the task on" — the
  # refusal written for a *misconfigured* connection, on a correct one.
  @impl true
  def connect(_name, opts) do
    case Keyword.get(opts, :command) do
      # A subprocess this VM is not going to start. What a browser on this
      # machine offers is set by the test the way the scope is, so a criterion
      # about reaching one does not need Chrome.
      nil -> {:ok, {__MODULE__, session(opts)}}
      _command -> {:ok, {__MODULE__, :browser}}
    end
  end

  defp session(opts) do
    %{
      agent_id: Keyword.get(opts, :agent_id),
      working_copy_id: Keyword.get(opts, :working_copy_id),
      headers: Keyword.get(opts, :headers, %{})
    }
  end

  @impl true
  def call({__MODULE__, session}, "run_script", %{"script" => script} = arguments) do
    dispatch(RunScript, script_params(script, arguments), session)
  end

  def call({__MODULE__, session}, "run_browser_script", %{"script" => script} = arguments) do
    dispatch(RunBrowserScript, browser_params(script, arguments), session)
  end

  def call({__MODULE__, session}, "tool_docs", arguments) do
    dispatch(ToolDocs, docs_params(arguments), session)
  end

  def call({__MODULE__, :browser}, tool, arguments) do
    if tool in browser_tools(),
      do: {:ok, "#{tool} ran with #{inspect(arguments)}"},
      else: {:error, "This machine's browser has no tool called #{inspect(tool)}."}
  end

  # Everything else the agent's surface carries, dispatched the way the wire
  # would have dispatched it.
  #
  # Until 2026-09-17 this clause was the refusal below and nothing else, so an
  # in-process agent could reach exactly three tools: `run_script`,
  # `run_browser_script` and `tool_docs`. Every direct one —
  # `get_next_requirement`, `start_task`, `evaluate_task`, `tap_out` — answered
  # "This server has no tool called …", which is the same sentence a genuinely
  # missing tool answers with.
  #
  # Nothing noticed because nothing in the suite had ever let an agent take a
  # real turn and then looked at what it called. The first thing that did
  # (story 1070's criterion 3539) hit it on its first run, and the agent's own
  # conduct was correct: it reported the refusal and would not improvise around
  # it.
  #
  # `validate_input` then `handler.execute/2` is exactly what
  # `Anubis.Server.Handlers.Tools.handle_call/3` does, so the coercion a tool
  # relies on happens here too — a params map with string keys reaching a tool
  # that reads atoms is a failure the real path does not have.
  def call({__MODULE__, session}, tool, arguments) do
    case Enum.find(LocalServer.registrations(), &(&1.name == tool)) do
      nil -> {:error, "This server has no tool called #{inspect(tool)}."}
      component -> dispatch_component(component, arguments || %{}, session)
    end
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

  defp dispatch_component(%{validate_input: nil} = component, _arguments, session),
    do: dispatch(component, %{}, session)

  defp dispatch_component(component, arguments, session) do
    case component.validate_input.(arguments) do
      {:ok, params} -> dispatch(component, params, session)
      {:error, errors} -> {:error, "#{component.name} was called wrong: #{inspect(errors)}"}
    end
  end

  # A library tool (`LocalServer.library_tools/0`) has no handler: the server
  # runs it, as it does for a real call.
  defp run(%{tool: _} = registration, params, frame),
    do: LocalServer.handle_tool_call(registration.name, params, frame)

  defp run(module, params, frame) when is_atom(module), do: module.execute(params, frame)
  defp run(component, params, frame), do: component.handler.execute(params, frame)

  defp dispatch(component, params, session) do
    case scope() do
      nil ->
        {:error,
         "No scope is configured for the local MCP transport. Set " <>
           "`:harness_mcp_scope` to the scope this agent runs as."}

      scope ->
        {:reply, response, _frame} = run(component, params, frame(scope, session))

        answer(response)
    end
  end

  # The frame the server builds for this connection. `agent_id` is an assign
  # rather than an argument for the reason `CmsHarness.Mcp.connect/3` states:
  # naming a subject is not claiming to be one, so who is calling comes off the
  # connection and never out of the model's own words.
  defp frame(scope, %{agent_id: agent_id}) when is_binary(agent_id),
    do: %Frame{assigns: %{current_scope: scope, agent_id: agent_id}}

  defp frame(scope, _session), do: %Frame{assigns: %{current_scope: scope}}

  # An `isError` response is the tool refusing, and a refusal has to arrive as
  # one — `run_script` reports a refused call by returning an error, and a
  # criterion asserting on the refusal would otherwise assert on a success.
  defp answer(%{isError: true} = response), do: {:error, text(response)}
  defp answer(response), do: {:ok, text(response)}

  defp text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp text(other), do: inspect(other)

  defp scope, do: Application.get_env(:code_my_spec, :harness_mcp_scope)

  defp browser_tools, do: Application.get_env(:code_my_spec, :harness_browser_tools, [])
end
