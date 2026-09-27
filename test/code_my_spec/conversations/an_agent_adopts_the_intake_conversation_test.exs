defmodule CodeMySpec.Conversations.AnAgentAdoptsTheIntakeConversationTest do
  @moduledoc """
  `Intake.convert/2` opens a `session_external_id`-keyed conversation
  (`"intake:<plan id>"`) to carry the guided-intake interview forward — see
  `find_or_create_session_conversation/3`'s own moduledoc: "the story
  interview... only borrowed the shape."

  Without this, the first real agent a project gets would never find that
  row: `find_or_create_agent_conversation/3` is keyed strictly on `agent_id`,
  so it would insert a second conversation, and `get_agent_conversation/2`'s
  "most recently updated" pick would then show the agent's own thread and
  silently drop the interview history from view — the exact bug this fixes,
  one level down from where a person would ever see it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message

  # A conversation is keyed on a real agent — `agent_id` is a foreign key —
  # so adoption has to be exercised against one, the same as
  # `OneProjectsThreadIsNotReadableFromAnotherTest`'s own fixture.
  defp agent_fixture(scope, project) do
    scope = %{scope | active_project: project, active_project_id: project.id}

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/intake-adoption-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    agent
  end

  setup do
    scope = full_scope_fixture()
    session_id = "intake:#{Ecto.UUID.generate()}"

    {:ok, intake} =
      Conversations.find_or_create_session_conversation(
        scope.active_account_id,
        scope.active_project_id,
        session_id
      )

    {:ok, project} = CodeMySpec.Projects.get_project(scope, scope.active_project_id)

    %{scope: scope, project: project, intake: intake}
  end

  test "the first agent adopts the intake conversation rather than starting a second one", %{
    scope: scope,
    project: project,
    intake: intake
  } do
    agent = agent_fixture(scope, project)

    assert {:ok, conversation} =
             Conversations.find_or_create_agent_conversation(
               scope.active_account_id,
               project.id,
               agent.id
             )

    assert conversation.id == intake.id,
           "a second conversation was created — the interview history this project already " <>
             "had is now on a row nothing shows"

    assert conversation.agent_id == agent.id
  end

  test "adoption keeps the messages already written", %{
    scope: scope,
    project: project,
    intake: intake
  } do
    {:ok, _} = Conversations.add_message(intake, :user, "a booking tool for hair salons")
    agent = agent_fixture(scope, project)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        project.id,
        agent.id
      )

    texts =
      conversation
      |> Conversations.list_messages()
      |> Enum.map(&Message.text/1)

    assert "a booking tool for hair salons" in texts
  end

  test "a second agent gets its own conversation — adoption happens once", %{
    scope: scope,
    project: project,
    intake: intake
  } do
    first_agent = agent_fixture(scope, project)

    {:ok, first} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        project.id,
        first_agent.id
      )

    assert first.id == intake.id

    second_agent = agent_fixture(scope, project)

    assert {:ok, second} =
             Conversations.find_or_create_agent_conversation(
               scope.active_account_id,
               project.id,
               second_agent.id
             )

    refute second.id == first.id,
           "a project's second agent adopted the first agent's own conversation — " <>
             "list_agent_conversations/2 exists because a project can have several"
  end

  test "a conversation with no session id is never adopted", %{scope: scope} do
    other_project =
      CodeMySpec.ProjectsFixtures.project_fixture(scope,
        account_id: scope.active_account_id,
        name: "no intake here"
      )

    agent = agent_fixture(scope, other_project)

    assert {:ok, conversation} =
             Conversations.find_or_create_agent_conversation(
               scope.active_account_id,
               other_project.id,
               agent.id
             )

    assert is_nil(conversation.session_external_id),
           "a project with no prior intake conversation adopted something anyway"
  end
end
