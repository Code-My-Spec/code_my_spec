defmodule CodeMySpecSpex.HarnessLifecycleHelpers do
  @moduledoc """
  Story 1051's shared premise: a real agent, on a real checkout, whose harness
  can be restarted underneath it.

  Every criterion on this story is about what survives a lifecycle event — a
  harness coming back, an agent stopped and started, a turn interrupted — and
  none of them is answerable against a row. The story's own note is the
  incident: a stale MCP client left an agent toolless for four hours, and
  restarting the *agent* made it worse. A double that answered "started" without
  a process would have agreed with every one of those four hours.

  So the agents here are started through `StartAgent`, the tool an operator
  actually calls, which in test reaches `CodeMySpecTest.InProcessAgentTransport`
  — the real `CmsHarness.Agents.launch/1` with the channel removed and nothing
  else. The tools they carry are asked of the running process, and the harness
  restart is `AgentProcessHelpers.restart_harness/1`, which is the harness's own
  restore loop over the socket the checkout joined on.

  Starting reaches no provider: `Alloy.Agent.Server` only calls a model when
  something chats to it, so the whole lifecycle runs without spending anything.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  # `live/2` falls back to `get/2` when the page is not already a LiveView, so
  # it has to be in scope or the call does not compile.
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers, only: [given_a_main_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  @doc """
  A checkout on this machine, joined, designated main, with a provider connected.

  The provider is part of the premise rather than an incidental: `start_agent/2`
  resolves a credential before it attempts anything, deliberately, so an agent
  with no usable one is refused here instead of failing on its first model call
  minutes later. Without it every scenario on this story would fail at the
  premise and say nothing about lifecycles.

  Answers the context with `:copy`, `:copy_id` and `:harness_socket` added, and
  `:scope` pointed at the copy — which is what makes an agent started next land
  on it rather than on the scope's default.
  """
  @spec given_a_staffed_checkout(map(), String.t()) :: map()
  def given_a_staffed_checkout(context, label) do
    context = given_a_main_checkout(context, label)

    scope = %{context.scope | active_working_copy_id: context.copy_id}
    {:ok, _integration} = Fixtures.connect_provider(scope, :zai)

    # Whose authority the agent's own tool calls are made with. The local MCP
    # transport reads it from application env, so without it a script the agent
    # runs is refused for having no scope — which reads as "its tools are
    # broken" and would make every criterion here pass or fail for the wrong
    # reason. Restored afterwards: application env is global, and a scope left
    # behind belongs to a project the next spex has never heard of.
    prior = Application.get_env(:code_my_spec, :harness_mcp_scope)
    Application.put_env(:code_my_spec, :harness_mcp_scope, scope)
    on_exit(fn -> restore_mcp_scope(prior) end)

    Map.put(context, :scope, scope)
  end

  defp restore_mcp_scope(nil), do: Application.delete_env(:code_my_spec, :harness_mcp_scope)
  defp restore_mcp_scope(scope), do: Application.put_env(:code_my_spec, :harness_mcp_scope, scope)

  @doc """
  Start an agent on that checkout, through the tool an operator calls.

  Answers the id, which is the whole handle. Asserted rather than pattern
  matched so a refusal names itself — "the premise never started" is otherwise
  a `nil` id and a confusing failure three steps later.
  """
  @spec start_agent(map(), map()) :: String.t()
  def start_agent(context, overrides \\ %{}) do
    params = Map.merge(%{role: "coding", working_copy_id: context.copy_id}, overrides)
    response = call(StartAgent, params, context)

    refute response.isError,
           """
           The premise is an agent that started, and this one was refused — so
           what follows would be about a checkout with no agent on it rather
           than about a lifecycle.

           #{response_text(response)}
           """

    id = agent_id_in(response_text(response))

    assert id,
           "the tool reported success without naming an agent:\n#{response_text(response)}"

    id
  end

  @doc "Stop one agent, through the operator's own tool. Answers the response."
  @spec stop_agent(map(), String.t()) :: struct()
  def stop_agent(context, agent_id), do: call(StopAgent, %{agent_id: agent_id}, context)

  @doc """
  What the project reports is running, as text.

  The surface an operator or the main agent reads, rather than a repository
  call — "it is not shown as running" is a claim about this listing, and a row
  that says `:starting` while the listing says "running" is exactly the gap
  criterion 3211 is about.
  """
  @spec listing(map()) :: String.t()
  def listing(context), do: ListAgents |> call(%{}, context) |> response_text()

  @doc "The frame a tool call from this scope is made in."
  @spec frame(map()) :: Frame.t()
  def frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  @doc """
  What one agent carries, by name, asked of the running process.

  Not of a list in the source: a constant naming two modules is true of the
  constant and says nothing about the agent that came back from a restart,
  which is the whole subject here.
  """
  @spec carried_tools(String.t()) :: [String.t()]
  def carried_tools(agent_id), do: agent_id |> Fixtures.agent_tools() |> Enum.map(& &1.name())

  @doc """
  Run a script as that agent, through the tool it carries.

  A tool *call*, rather than a tool *list*. The four-hour incident was an agent
  whose tools were listed and did not work, so "its tools resolve" has to be
  answered by something actually running.
  """
  @spec tool_call(String.t(), String.t()) :: term()
  def tool_call(agent_id, script \\ "return list_stories({})"),
    do: Fixtures.run_script(script, Fixtures.agent_tool_context(agent_id))

  @doc """
  One agent's transcript, as the page renders it.

  The scrolling region rather than the whole document, because the criteria
  either side of this compare a before against an after and the document does
  not compare: the CSRF token is regenerated on every render, so two identical
  pages differ. Comparing them made "nothing was added" fail on every run and
  "something was added" pass on every run — the two halves of this story's
  restart-notification rule, each broken in the direction that hides it.
  """
  @spec transcript(map(), String.t()) :: String.t()
  def transcript(context, path) do
    {:ok, view, _html} = live(context.conn, path)

    view |> element("[data-test='conversation-scroll']") |> render()
  end

  @doc """
  Make a tool call and say how it ended — with a value, or by raising.

  Here rather than in the criterion because the distinction *is* the criterion:
  3212 says a lost tool surface must be raised rather than handed back as a
  result the model reads, and both outcomes have to be observable from one call
  for that to be assertable at all.
  """
  @spec attempt_tool_call(String.t()) :: {:returned, term()} | {:raised, Exception.t()}
  def attempt_tool_call(agent_id) do
    {:returned, tool_call(agent_id)}
  rescue
    error -> {:raised, error}
  end

  @doc "The agent id in a tool reply, or nil if it named none."
  @spec agent_id_in(String.t()) :: String.t() | nil
  def agent_id_in(text) do
    case Regex.run(~r/Agent: ([0-9a-f-]{36})/, text) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp call(tool, params, context) do
    {:reply, response, _frame} = tool.execute(params, frame(context))
    response
  end
end
