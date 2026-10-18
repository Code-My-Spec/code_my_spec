defmodule CodeMySpec.Agents.ATerminalSessionJoinsAsAnAgentTest do
  @moduledoc """
  Story 1122: a Claude Code session in a person's terminal joins the project as
  an agent, keyed on Claude Code's own session id. It may take any role on any
  copy, even one an agent we started already holds (John, 2026-10-18), and it
  is main unless it agrees otherwise with the person.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Hooks.SessionStart
  alias CodeMySpec.ToolLibrary

  setup do
    scope = full_scope_fixture()
    root = "/workspace/terminal-#{System.unique_integer([:positive])}"

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "the main checkout",
        root: root,
        device: device_fixture(scope)
      )

    {:ok, copy} = CodeMySpec.WorkingCopies.report_root(copy, root)

    %{scope: %{scope | active_working_copy_id: copy.id}, copy: copy}
  end

  defp session_id, do: "cc-#{System.unique_integer([:positive])}"

  test "a session registers as a main Claude Code agent on its copy, not woken idle", %{
    scope: scope,
    copy: copy
  } do
    session = session_id()

    assert {:ok, %Agent{} = agent} = Agents.register_terminal(scope, session)

    assert agent.engine == :claude_code
    assert agent.engine_session_id == session
    assert agent.role == :main
    assert agent.working_copy_id == copy.id
    assert agent.working_copy == copy.root
    refute agent.continuous
  end

  test "a resumed session gets its agent back", %{scope: scope} do
    session = session_id()
    {:ok, first} = Agents.register_terminal(scope, session)

    assert {:ok, again} = Agents.register_terminal(scope, session)
    assert again.id == first.id
    assert length(AgentsRepository.list_agents(scope)) == 1
  end

  test "two terminal windows on one copy are two agents", %{scope: scope} do
    {:ok, one} = Agents.register_terminal(scope, session_id())
    {:ok, two} = Agents.register_terminal(scope, session_id())

    refute one.id == two.id
    assert one.working_copy_id == two.working_copy_id
  end

  test "a terminal agent takes a role an agent we started already holds", %{
    scope: scope,
    copy: copy
  } do
    {:ok, alloy_main} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :main,
        working_copy_id: copy.id,
        working_copy: copy.root
      })

    assert {:ok, terminal} = Agents.register_terminal(scope, session_id())

    assert terminal.role == :main
    refute terminal.id == alloy_main.id
  end

  test "the agent sets the role it chose with the person; an agent we started cannot", %{
    scope: scope,
    copy: copy
  } do
    session = session_id()
    {:ok, agent} = Agents.register_terminal(scope, session)

    assert {:ok, said} =
             ToolLibrary.run("set_my_role", %{"role" => "qa", "session_id" => session}, %{
               scope: scope
             })

    assert said =~ "qa agent"
    assert {:ok, %Agent{role: :qa}} = Agents.fetch_agent(scope, agent.id)

    {:ok, alloy} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :coding,
        working_copy_id: copy.id,
        working_copy: copy.root
      })

    assert {:error, :not_a_terminal_agent} = Agents.set_terminal_role(scope, alloy, :main)
  end

  test "set_my_role without a registered session says how to get one", %{scope: scope} do
    assert {:error, reason} =
             ToolLibrary.run("set_my_role", %{"role" => "qa", "session_id" => session_id()}, %{
               scope: scope
             })

    assert reason =~ "No agent is registered for this session"
  end

  # John, 2026-10-18: the terminal main gets main's duties while it is live,
  # the main we run otherwise.
  test "a terminal main is the main only while it is live", %{scope: scope, copy: copy} do
    {:ok, ours} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :main,
        working_copy_id: copy.id,
        working_copy: copy.root
      })

    {:ok, terminal} = Agents.register_terminal(scope, session_id())

    assert Enum.map(Agents.running_main_agents(scope), & &1.id) == [ours.id]

    CodeMySpecTest.AgentPresence.present(terminal)

    assert Enum.map(Agents.running_main_agents(scope), & &1.id) == [terminal.id, ours.id]
  end

  test "a live terminal main on another copy is not asked to do main's work", %{
    scope: scope,
    copy: main_copy
  } do
    {:ok, ours} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :main,
        working_copy_id: main_copy.id,
        working_copy: main_copy.root
      })

    root = "/workspace/feature-#{System.unique_integer([:positive])}"

    {:ok, feature} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a feature checkout",
        root: root,
        device: device_fixture(scope)
      )

    {:ok, feature} = CodeMySpec.WorkingCopies.report_root(feature, root)

    {:ok, elsewhere} =
      Agents.register_terminal(%{scope | active_working_copy_id: feature.id}, session_id())

    CodeMySpecTest.AgentPresence.present(elsewhere)

    assert Enum.map(Agents.running_main_agents(scope), & &1.id) == [ours.id]
  end

  test "the SessionStart hook registers the agent and tells it who it is", %{scope: scope} do
    session = session_id()

    assert {200, body} = SessionStart.handle(scope, %{"session_id" => session})

    agent = AgentsRepository.get_by_engine_session(scope, session)
    assert %Agent{role: :main} = agent

    context = body.hookSpecificOutput.additionalContext
    assert body.hookSpecificOutput.hookEventName == "SessionStart"
    assert context =~ agent.id
    assert context =~ "set_my_role"
  end

  # The proof run, 2026-10-18: a terminal turn's usage showed up in its
  # conversation as "assistant: %{usage: ...}".
  test "a terminal turn's usage is not written to its conversation as speech", %{scope: scope} do
    {:ok, agent} = Agents.register_terminal(scope, session_id())

    :ok =
      Agents.record_turn_event(scope, agent.id, %{
        "kind" => "turn_usage",
        "text" => ~s(%{usage: %{"output_tokens" => 629}}),
        "usage" => %{"output_tokens" => 629}
      })

    {:ok, conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    refute Enum.any?(
             CodeMySpec.Conversations.list_messages(conversation),
             &(CodeMySpec.Conversations.Message.text(&1) =~ "usage")
           )
  end
end
