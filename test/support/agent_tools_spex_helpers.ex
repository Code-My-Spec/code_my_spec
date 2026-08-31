defmodule CodeMySpecSpex.AgentToolsHelpers do
  @moduledoc """
  Story 1038's shared premise: an agent that is really running on this machine.

  Every criterion here is about what an agent *carries* or what a script it runs
  can reach, and neither is answerable from a list in the source — a constant
  naming two modules is true of the constant and says nothing about the agent
  that was started. So these start one, through `CmsHarness.Agents.launch/1`,
  the same call the server makes over the channel.

  Starting reaches no provider. `Alloy.Agent.Server` only calls a model when
  something chats to it, so the credential below is never used and the whole
  lifecycle runs for real without spending anything.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CodeMySpecSpex.Fixtures

  
  @doc """
  Launch request for an agent on a real directory, defaulting to the coding
  type. Pass `%{"role" => "qa"}` for the criteria about what a type may reach.
  """
  @spec launch_request(map(), map()) :: map()
  def launch_request(context, overrides \\ %{}) do
    # The server's own agent row, and its id is what the machine runs under.
    # That is how it works in production — `Agents.start_agent/2` hands the row
    # id to the machine — and it is what makes the scoping criteria real: which
    # tools an agent may call is read off that row, so an invented id would be
    # asserting against no row at all.
    agent = Fixtures.running_agent(context.scope, role: Map.get(overrides, "role", "coding"))

    Map.merge(
      %{
        "agent_id" => agent.id,
        "provider" => "zai",
        # Never reached: nothing here chats to the agent. Present because a
        # provider that needs a key and does not get one is a different failure
        # with its own criterion.
        "api_key" => "not-a-real-key",
        "working_copy" => checkout(context),
        "role" => "coding"
      },
      overrides
    )
  end

  @doc """
  A machine with a browser on it, reporting what it offers.

  Eighty-five names, because that is what `vibium mcp` answers `tools/list`
  with, and the whole argument is about that number. Not the twenty-nine
  `plugins/claude/agents/qa.md` grants — that is what the plugin hands out, and
  the tools it does not hand out cost just as much to carry. Set the way
  scope is — the local transport reads it from the test process — so a criterion
  about reaching a browser does not need Chrome, a subprocess, or a machine that
  happens to have vibium installed.

  Recorded against the working copy as well, because that is where an agent's
  list is computed from: reporting to the transport alone would prove the
  session and nothing about what an agent started here carries.
  """
  @spec fake_browser(map()) :: [String.t()]
  def fake_browser(context) do
    offered =
      for n <- 1..85, do: "browser_#{Enum.at(~w(click fill type screenshot find), rem(n, 5))}_#{n}"

    prior = Application.get_env(:code_my_spec, :harness_browser_tools)
    Application.put_env(:code_my_spec, :harness_browser_tools, offered)
    on_exit(fn -> restore_browser(prior) end)

    Fixtures.record_machine_tools(context.scope, offered)

    offered
  end

  defp restore_browser(nil), do: Application.delete_env(:code_my_spec, :harness_browser_tools)

  defp restore_browser(tools),
    do: Application.put_env(:code_my_spec, :harness_browser_tools, tools)

  @doc "Start one and stop it when the scenario ends."
  @spec running_agent(map(), map()) :: String.t()
  def running_agent(context, overrides \\ %{}) do
    CmsHarnessTest.Machine.ensure_supervisor()

    # Whose authority a script runs with. The local transport reads it the way
    # `Project.Transport.Test` reads its owner, and it is the agent's own — so
    # the isolation criterion is real rather than circular: another project's
    # story is refused by the tool's own scoping, not by anything here.
    prior = Application.get_env(:code_my_spec, :harness_mcp_scope)
    Application.put_env(:code_my_spec, :harness_mcp_scope, context.scope)
    on_exit(fn -> restore_scope(prior) end)

    {:ok, %{agent_id: id}} = Fixtures.launch_agent(launch_request(context, overrides))
    on_exit(fn -> Fixtures.halt_agent(id) end)

    id
  end

  defp restore_scope(nil), do: Application.delete_env(:code_my_spec, :harness_mcp_scope)
  defp restore_scope(scope), do: Application.put_env(:code_my_spec, :harness_mcp_scope, scope)

  @doc """
  The context this agent's own tool calls are made with.

  Taken off the running agent rather than built here, because the session is
  the authority: a context assembled in a spec would carry whatever the spec
  put in it, and a script acting with the agent's authority is the thing half
  these criteria are about.
  """
  @spec agent_context(map()) :: map()
  def agent_context(%{agent_id: agent_id}), do: Fixtures.agent_tool_context(agent_id)

  @doc """
  A directory for the agent to run in.

  Real, because the core tools are scoped to it by path and a checkout that
  does not exist is a different failure from one the agent may not read outside
  of.
  """
  @spec checkout(map()) :: String.t()
  def checkout(_context) do
    dir = CodeMySpec.TempFile.dir("spex_1038")
    File.mkdir_p!(dir)
    dir
  end
end
