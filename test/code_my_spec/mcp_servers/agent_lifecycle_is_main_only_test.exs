defmodule CodeMySpec.McpServers.AgentLifecycleIsMainOnlyTest do
  @moduledoc """
  Starting, turning off, turning on, retiring and restarting an agent are
  reached through `run_script`, by the main agent and by a caller with no agent
  identity (a person or operator session). Coding, QA and product are refused.

  None of the five is on the spine or carried directly by an in-app agent.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CmsHarness.Agents.Engine
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.LocalServer

  @missing "00000000-0000-0000-0000-000000000000"

  # Arguments that pass schema validation and fail inside the tool, so a call
  # that is not refused reaches the tool and changes nothing.
  @calls %{
    "start_agent" => ~s[{ role = "qa", provider = "no-such-provider" }],
    "turn_off_agent" => ~s[{ agent_id = "#{@missing}" }],
    "turn_on_agent" => ~s[{ agent_id = "#{@missing}" }],
    "retire_agent" => ~s[{ agent_id = "#{@missing}" }],
    "restart_agent" => ~s[{ agent_id = "#{@missing}", reason = "test" }]
  }

  @lifecycle Map.keys(@calls)

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        working_copy: "/tmp/lifecycle-#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id,
        tools: nil
      })

    agent
  end

  defp run(frame, name, agent_id) do
    script = "local _, err = #{name}(#{@calls[name]}) return \"reached\""
    {:reply, response, _frame} = RunScript.execute(params(script, agent_id), frame)
    text = response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")
    {response.isError, text}
  end

  defp params(script, nil), do: %{script: script}
  defp params(script, agent_id), do: %{script: script, agent_id: agent_id}

  test "none of the five is on the spine or carried directly" do
    spine = Enum.map(LocalServer.__components__(), & &1.name)
    carried = [role: :main] |> Engine.tools() |> Enum.map(& &1.name())

    for name <- @lifecycle do
      refute name in spine, "`#{name}` is on the spine"
      refute name in carried, "`#{name}` is carried directly by the engine"
    end
  end

  test "the main agent's code-mode grant has all five, and a script reaches each" do
    scope = full_scope_fixture()
    main = agent(scope, "main")
    catalog = Layer.catalog(scope, Agents.tools_of(scope, main))
    frame = %Frame{assigns: %{current_scope: scope, agent_id: main.id}}

    for name <- @lifecycle do
      assert Map.has_key?(catalog, name), "the main agent's catalog lacks `#{name}`"

      {error?, text} = run(frame, name, main.id)
      refute error?, "main could not call `#{name}` from a script:\n\n#{text}"
      assert text =~ "reached"
    end
  end

  test "a caller with no agent identity reaches all five" do
    scope = full_scope_fixture()
    frame = %Frame{assigns: %{current_scope: scope}}

    for name <- @lifecycle do
      {error?, text} = run(frame, name, nil)
      refute error?, "an operator session could not call `#{name}` from a script:\n\n#{text}"
      assert text =~ "reached"
    end
  end

  for role <- ~w(coding qa product) do
    test "a #{role} agent is refused each one, with a reason" do
      scope = full_scope_fixture()
      scoped = agent(scope, unquote(role))
      frame = %Frame{assigns: %{current_scope: scope, agent_id: scoped.id}}

      for name <- @lifecycle do
        {error?, text} = run(frame, name, scoped.id)
        assert error?, "a #{unquote(role)} agent called `#{name}` from a script"

        assert text =~ "#{name} is not a tool a #{unquote(role)} agent carries",
               "a #{unquote(role)} agent was refused `#{name}` without the role reason:\n\n#{text}"
      end
    end
  end
end
