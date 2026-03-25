defmodule CodeMySpec.McpServers.Issues.Tools.LifecycleTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, DismissIssue, ResolveIssue}
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "AcceptIssue" do
    test "accepts an incoming issue" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AcceptIssue.execute(%{issue_id: issue.id}, frame)
      assert response.isError == false

      content = response_text(response)
      assert content =~ "accepted"
    end

    test "returns error for non-existent issue" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               AcceptIssue.execute(%{issue_id: "00000000-0000-0000-0000-000000000000"}, frame)

      assert response.isError == true
    end
  end

  describe "DismissIssue" do
    test "dismisses an incoming issue with reason" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               DismissIssue.execute(%{issue_id: issue.id, reason: "Not a real bug"}, frame)

      assert response.isError == false

      content = response_text(response)
      assert content =~ "dismissed"
    end
  end

  describe "ResolveIssue" do
    test "resolves an accepted issue with resolution" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      {:ok, accepted} = CodeMySpec.Issues.accept_issue(scope, issue)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ResolveIssue.execute(
                 %{issue_id: accepted.id, resolution: "Fixed in commit abc123"},
                 frame
               )

      assert response.isError == false

      content = response_text(response)
      assert content =~ "resolved"
    end

    test "cannot resolve an incoming issue directly" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ResolveIssue.execute(
                 %{issue_id: issue.id, resolution: "Tried to skip accept"},
                 frame
               )

      assert response.isError == true
    end
  end

  describe "full lifecycle" do
    test "incoming → accepted → resolved" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{title: "Lifecycle Test", severity: :high})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, accept_resp, ^frame} = AcceptIssue.execute(%{issue_id: issue.id}, frame)
      assert accept_resp.isError == false

      assert {:reply, resolve_resp, ^frame} =
               ResolveIssue.execute(
                 %{issue_id: issue.id, resolution: "All fixed"},
                 frame
               )

      assert resolve_resp.isError == false
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
