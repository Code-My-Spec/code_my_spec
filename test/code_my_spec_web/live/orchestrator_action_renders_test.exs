defmodule CodeMySpecWeb.OrchestratorActionRendersTest do
  @moduledoc """
  A recorded orchestrator action is visible in the transcript.

  The other half of story 985, and the half that fails silently: an action
  written and not rendered is exactly as invisible as one never written, and
  from the page there is no way to tell those apart.

  `ConversationsOrchestratorActionTest` covers the record and
  `HookNotesTheDecisionTest` covers the decision reaching it. This covers the
  reading, which is what the story is actually about.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.LiveViewTest

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Conversation
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup %{scope: scope} do
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
    root = CodeMySpec.TempFile.dir("renders_action")
    File.mkdir_p!(root)

    copy |> Ecto.Changeset.change(root: root, main: true) |> CodeMySpec.Repo.update!()
    scope = %{scope | cwd: root}

    {:ok, agent} =
      Agents.start_agent(scope, %{
        provider: "anthropic",
        role: "coding",
        engine: :alloy,
        working_copy: root
      })

    %{scope: scope, agent: agent}
  end

  defp transcript(conn, agent) do
    conversation = CodeMySpec.Repo.get_by(Conversation, agent_id: agent.id)

    {:ok, _live, html} =
      live(
        conn,
        "/app/projects/#{conversation.project_id}/agent-conversation?conversation=#{conversation.id}"
      )

    html
  end

  test "the action is drawn in the transcript", %{conn: conn, agent: agent} do
    {:ok, _} =
      Conversations.record_orchestrator_action(agent, "Stopped you: compile failed.",
        count: "3 problems",
        tool: "list_problems"
      )

    html = transcript(conn, agent)

    assert html =~ "orchestrator-action",
           "the action was written and the page does not draw it. From the transcript " <>
             "that is indistinguishable from never having recorded it, which is the " <>
             "failure this story exists to end."

    assert html =~ "Stopped you: compile failed."
  end

  test "the count and the tool are drawn as their own things", %{conn: conn, agent: agent} do
    {:ok, _} =
      Conversations.record_orchestrator_action(agent, "Stopped you.",
        count: "3 problems",
        tool: "list_problems"
      )

    html = transcript(conn, agent)

    assert html =~ "orchestrator-action-count",
           "the count is not rendered distinctly, so a reader has to find a number in " <>
             "a sentence."

    assert html =~ "list_problems",
           "the tool that answers for the detail is missing, so the summary is " <>
             "something the reader has to take on trust."
  end

  test "it is not drawn as a tool the agent called", %{conn: conn, agent: agent} do
    {:ok, _} = Conversations.record_orchestrator_action(agent, "Stopped you.")

    html = transcript(conn, agent)

    refute html =~ ~r/data-test="orchestrator-action"[^>]*data-role="assistant"/,
           "the action is attributed to the agent. What was done *to* it reading as " <>
             "something it did makes a reader draw a conclusion about the agent's " <>
             "judgement from the orchestrator's act."
  end
end
