defmodule CodeMySpecLocalWeb.HookNotesTheDecisionTest do
  @moduledoc """
  The decision reaches the conversation through the hook endpoint, not only
  through `Stop.decide/2`.

  `StopNotesTheDecisionTest` drives the decision directly and passes. The spex
  drive the endpoint and see nothing, so the difference is the scope the
  `HarnessScope` plug builds — which is the scope every real hook actually
  arrives with. A seam proven only by its own caller is not proven.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Conversation

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
    root = CodeMySpec.TempFile.dir("hook_notes")
    File.mkdir_p!(root)

    copy =
      copy
      |> Ecto.Changeset.change(root: root, main: true)
      |> CodeMySpec.Repo.update!()

    scope = %{scope | cwd: root}

    {:ok, agent} =
      Agents.start_agent(scope, %{
        provider: "anthropic",
        role: "coding",
        engine: :alloy,
        working_copy: root
      })

    %{scope: scope, copy: copy, agent: agent}
  end

  defp orchestrator_messages(agent) do
    case CodeMySpec.Repo.get_by(Conversation, agent_id: agent.id) do
      nil ->
        []

      conversation ->
        conversation |> Conversations.list_messages() |> Enum.filter(&(&1.role == :orchestrator))
    end
  end

  test "a stop through the endpoint lands on the agent's thread", %{copy: copy, agent: agent} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-harness-id", copy.id)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/api/hooks/stop", %{"session_id" => "a-session-nobody-registered"})

    assert conn.status == 200, "the hook did not answer: #{conn.status}"

    assert [_action] = orchestrator_messages(agent),
           "the hook decided and wrote nothing to the conversation. The scope the " <>
             "HarnessScope plug builds is the one every real hook arrives with, so a " <>
             "recorder that only fires for a hand-built scope fires for nobody."
  end
end
