defmodule CodeMySpec.McpServers.Tasks.Tools.DraftTaskTest do
  use ExUnit.Case, async: true

  import CodeMySpec.SessionsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.Tools.DraftTask

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns all complete when no actionable requirements" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               DraftTask.execute(%{session_id: session.id}, frame)

      assert response.isError != true
      content = response_text(response)
      assert content =~ "complete" or content =~ "No actionable"
    end

    test "returns error for non-existent session" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               DraftTask.execute(%{session_id: "nonexistent"}, frame)

      assert response.isError == true
      assert response_text(response) =~ "Session not found"
    end

    test "returns error for non-existent UUID session" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               DraftTask.execute(%{session_id: Ecto.UUID.generate()}, frame)

      assert response.isError == true
      assert response_text(response) =~ "Session not found"
    end

    test "finds session by external conversation ID" do
      scope = full_scope_fixture()
      external_id = "ext-#{System.unique_integer([:positive])}"
      {:ok, _session} = CodeMySpec.Sessions.find_or_create_session(scope, external_id)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               DraftTask.execute(%{session_id: external_id}, frame)

      # Should resolve the session, not error
      assert response.isError != true
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} =
               DraftTask.execute(%{session_id: "anything"}, frame)

      assert response.isError == true
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
