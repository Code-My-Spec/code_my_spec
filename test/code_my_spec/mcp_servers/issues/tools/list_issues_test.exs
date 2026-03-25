defmodule CodeMySpec.McpServers.Issues.Tools.ListIssuesTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns all issues with no filters" do
      scope = full_scope_fixture()
      issue_fixture(scope, %{title: "Issue A", severity: :high})
      issue_fixture(scope, %{title: "Issue B", severity: :low})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListIssues.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false

      content = response_text(response)
      assert content =~ "2 issues"
      assert content =~ "Issue A"
      assert content =~ "Issue B"
    end

    test "filters by status" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{title: "Accepted One"})
      CodeMySpec.Issues.accept_issue(scope, issue)
      issue_fixture(scope, %{title: "Incoming One"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListIssues.execute(%{status: "accepted"}, frame)
      content = response_text(response)
      assert content =~ "Accepted One"
      refute content =~ "Incoming One"
    end

    test "filters by severity" do
      scope = full_scope_fixture()
      issue_fixture(scope, %{title: "Critical Bug", severity: :critical})
      issue_fixture(scope, %{title: "Minor Thing", severity: :info})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListIssues.execute(%{severity: "critical"}, frame)
      content = response_text(response)
      assert content =~ "Critical Bug"
      refute content =~ "Minor Thing"
    end

    test "returns empty state when no issues" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListIssues.execute(%{}, frame)
      content = response_text(response)
      assert content =~ "No issues found"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
