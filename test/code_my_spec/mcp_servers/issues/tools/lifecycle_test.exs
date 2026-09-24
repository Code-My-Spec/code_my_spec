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

  describe "UpdateIssue refuses what it cannot apply" do
    # Both parsers answered nil for anything unrecognised, `maybe_put/3` dropped
    # the key, and the call replied "updated" having changed nothing. Measured
    # 2026-09-23: `update_issue({category: "devops"})` reported success twice
    # while the row was untouched, and finding out why meant reading
    # `parse_category/1`. A write that reports success without writing is the
    # defect; the small vocabulary is not.
    test "an unrecognised category is refused by name, not dropped" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(%{issue_id: issue.id, category: "devops"}, frame)

      assert response.isError == true
      text = response_text(response)
      assert text =~ "not a category"
      assert text =~ "bug"

      assert Issues.get_issue(scope, issue.id).category == issue.category,
             "the row must be untouched when the call is refused"
    end

    test "an unrecognised severity is refused by name too" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(%{issue_id: issue.id, severity: "urgent"}, frame)

      assert response.isError == true
      assert response_text(response) =~ "not a severity"
    end

    test "a recognised category still applies" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(%{issue_id: issue.id, category: "bug"}, frame)

      assert response.isError == false
      assert Issues.get_issue(scope, issue.id).category == :bug
    end
  end

  describe "UpdateIssue detach_from_story" do
    # `story_id` could be re-pointed at another story but never cleared, and
    # `story_id: null` is not expressible from a Lua table — `story_id = nil`
    # removes the key and reads as "not provided", so the call reported success
    # and left the attribution alone. Measured on Broken Oaths issue 93259261, a
    # UAT infrastructure failure that `Issues.attribute_to_story/3` had swept onto
    # story 950 and which then gated that story's completion, and through the
    # per-copy wave the whole fleet's only reachable work.
    test "clears the story a report was wrongly attributed to" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, _, ^frame} = UpdateIssue.execute(%{issue_id: issue.id, story_id: 950}, frame)
      assert Issues.get_issue(scope, issue.id).story_id == 950

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(%{issue_id: issue.id, detach_from_story: true}, frame)

      assert response.isError == false

      assert Issues.get_issue(scope, issue.id).story_id == nil,
             "sometimes the right story is none, and that has to be sayable"
    end

    test "false leaves the attribution alone" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, _, ^frame} = UpdateIssue.execute(%{issue_id: issue.id, story_id: 950}, frame)

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(
                 %{issue_id: issue.id, detach_from_story: false, append: "note"},
                 frame
               )

      assert response.isError == false
      assert Issues.get_issue(scope, issue.id).story_id == 950
    end
  end
end
