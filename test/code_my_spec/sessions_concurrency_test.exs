defmodule CodeMySpec.SessionsConcurrencyTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Sessions

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  describe "concurrent_sessions/2" do
    test "is empty when one agent is working the project", %{scope: scope} do
      {:ok, _} = Sessions.find_or_create_session(scope, "conversation-a", session_attrs())

      assert [] = Sessions.concurrent_sessions(scope, "conversation-a")
    end

    test "reports the other agent when two conversations are active", %{scope: scope} do
      {:ok, _a} = Sessions.find_or_create_session(scope, "conversation-a", session_attrs())
      {:ok, _b} = Sessions.find_or_create_session(scope, "conversation-b", session_attrs())

      # Each sees the other, which is what makes the condition detectable from
      # whichever agent happens to look — the one that arrived second has no
      # special knowledge that it was second.
      assert [%{external_conversation_id: "conversation-b"}] =
               Sessions.concurrent_sessions(scope, "conversation-a")

      assert [%{external_conversation_id: "conversation-a"}] =
               Sessions.concurrent_sessions(scope, "conversation-b")
    end

    test "a finished session is not a conflict", %{scope: scope} do
      {:ok, a} = Sessions.find_or_create_session(scope, "conversation-a", session_attrs())
      {:ok, _} = Sessions.update_session(scope, a, %{status: :complete})

      assert [] = Sessions.concurrent_sessions(scope, "conversation-b")
    end
  end

  defp session_attrs do
    %{state: %{}, status: :active, type: CodeMySpec.AgentTasks.ContextSpec}
  end
end
