defmodule CodeMySpec.McpServers.Issues.Tools.LifecycleTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Issues.Tools.ResolveIssue
  alias CodeMySpec.McpServers.Issues.Tools.UpdateIssue
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
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
      {:ok, accepted} = Issues.accept_issue(scope, issue)

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

  # An agent files when it has the evidence, which is usually before it
  # understands the defect — so reports go stale, and the only remedy used to be
  # a second issue. `1f60a145` cited the wrong log file and `b0486568` had to be
  # filed to say so, leaving two reports of one defect with the first still
  # sending its reader to a process that was not involved.
  describe "UpdateIssue append" do
    test "adds the correction and keeps the original text" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{description: "Cited server.log, which is the :4003 server."})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(
                 %{issue_id: issue.id, append: "Wrong log — the stop hook logs to web.log."},
                 frame
               )

      assert response.isError == false

      updated = Issues.get_issue(scope, issue.id)
      assert updated.description =~ "Cited server.log, which is the :4003 server."
      assert updated.description =~ "Wrong log — the stop hook logs to web.log."
      assert updated.description =~ "Correction / later evidence"
    end

    test "appends again without losing the first correction" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{description: "First account."})
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, _, ^frame} = UpdateIssue.execute(%{issue_id: issue.id, append: "Second."}, frame)
      issue = Issues.get_issue(scope, issue.id)
      {:reply, _, ^frame} = UpdateIssue.execute(%{issue_id: issue.id, append: "Third."}, frame)

      updated = Issues.get_issue(scope, issue.id)
      assert updated.description =~ "First account."
      assert updated.description =~ "Second."
      assert updated.description =~ "Third."
    end

    test "an append alone is enough — no other field required" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(%{issue_id: issue.id, append: "More evidence."}, frame)

      assert response.isError == false
    end

    test "still refuses an update that says nothing" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = UpdateIssue.execute(%{issue_id: issue.id}, frame)
      assert response.isError == true
      assert response_text(response) =~ "append"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
