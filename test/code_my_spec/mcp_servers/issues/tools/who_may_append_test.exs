defmodule CodeMySpec.McpServers.Issues.Tools.WhoMayAppendTest do
  @moduledoc """
  `append` is for whoever is working the issue; the triage fields stay product's.

  Issue `0074e1b8`. A coding agent was told, by main, to append a verification
  record to an issue with `update_issue`. It could not: `update_issue` appears
  only in `@product_tools`, so the call raised "update_issue is not a tool a
  coding agent carries". Retrying with a different spelling would not have
  helped, and the record was not lost only because product appended it by hand.

  The exclusion is half-deliberate. `accept_issue`/`dismiss_issue` are product's
  on purpose -- deciding whether a report is real is a triage call. But
  `update_issue` bundles two unlike capabilities: `append`, which only ever adds
  and exists precisely because reports go stale, and
  `severity`/`story_number`/`category`/`detach_from_story`, which are re-triage
  levers that belong with the accept/dismiss decision. So there was no way to
  grant the safe half, and the roles that discover a report has gone stale are
  exactly the ones working it.

  This is that split: the tool is granted to coding and qa, and the triage
  fields are refused for a caller who does not carry product's triage
  authority. `append` is allowed for anyone.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.UpdateIssue
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope)
    %{scope: scope, issue: issue}
  end

  describe "a coding agent" do
    test "may append, and the append lands", ctx do
      frame = frame_for(ctx.scope, :coding)

      assert {:reply, response, ^frame} =
               UpdateIssue.execute(
                 %{
                   issue_id: ctx.issue.id,
                   append: "Verification: 136 tests pass on candidate 3085ecad5."
                 },
                 frame
               )

      assert response.isError == false

      reloaded = Issues.get_issue(ctx.scope, ctx.issue.id)
      assert reloaded.description =~ "Verification: 136 tests pass on candidate 3085ecad5."
      assert reloaded.description =~ ctx.issue.description, "the original report must be kept"
    end

    test "may not re-triage severity", ctx do
      before = ctx.issue.severity
      frame = frame_for(ctx.scope, :coding)

      assert {:reply, response, _} =
               UpdateIssue.execute(%{issue_id: ctx.issue.id, severity: "low"}, frame)

      assert response.isError == true
      assert text(response) =~ ~r/triage|product/i
      assert Issues.get_issue(ctx.scope, ctx.issue.id).severity == before
    end

    test "may not detach from the story", ctx do
      frame = frame_for(ctx.scope, :coding)

      assert {:reply, response, _} =
               UpdateIssue.execute(
                 %{issue_id: ctx.issue.id, detach_from_story: true},
                 frame
               )

      assert response.isError == true
    end
  end

  describe "a qa agent" do
    test "may append", ctx do
      frame = frame_for(ctx.scope, :qa)

      assert {:reply, response, _} =
               UpdateIssue.execute(
                 %{issue_id: ctx.issue.id, append: "QA re-check: still reproducible."},
                 frame
               )

      assert response.isError == false
    end
  end

  describe "a product agent" do
    test "may still re-triage", ctx do
      frame = frame_for(ctx.scope, :product)

      assert {:reply, response, _} =
               UpdateIssue.execute(%{issue_id: ctx.issue.id, severity: "low"}, frame)

      assert response.isError == false
      assert Issues.get_issue(ctx.scope, ctx.issue.id).severity == :low
    end
  end

  # A frame carrying the agent's id, the way `AgentScope` puts one on the
  # connection. The tool resolves the id to a row and reads its role.
  defp frame_for(scope, role) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/#{role}-copy",
        working_copy_id: copy.id,
        role: role,
        status: :running
      })

    %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
  end

  defp text(response) do
    response
    |> Response.to_protocol()
    |> Map.fetch!("content")
    |> List.first()
    |> Map.fetch!("text")
  end
end
