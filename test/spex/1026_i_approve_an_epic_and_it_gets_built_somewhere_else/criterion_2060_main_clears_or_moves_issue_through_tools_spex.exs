defmodule CodeMySpecSpex.Story1026.Criterion2060Spex do
  @moduledoc """
  Story 1026 — Main clears or moves an issue's copy assignment through tools.
  Both operations run through main's run_script grant. The work listing
  exposes the resulting team assignments; clearing does not resolve the issue.
  The removal tool is named here as the contract still to be implemented.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main clears and moves issue assignments through tools", criterion: 2060 do
    scenario "Main clears the copy without resolving the issue" do
      given_ "main and an accepted issue assigned to team A", context do
        {:ok, assigned_issue(context)}
      end

      when_ "main calls the issue removal tool", context do
        script = """
        local result, err = unassign_issue_from_working_copy({
          issue_id = '#{context.issue_id}',
          working_copy_id = '#{context.scope.active_working_copy_id}'
        })
        if result == nil then error(err.message) end
        return result
        """

        {:reply, response, _} = RunScript.execute(%{script: script}, context.main_frame)
        {:ok, Map.put(context, :operation, response)}
      end

      then_ "both teammates are free and the issue remains accepted", context do
        refute context.operation.isError, response_text(context.operation)
        entries = work_entries(context)
        assert_free(entries, context.team)

        {:reply, response, _} =
          GetIssue.execute(%{issue_id: context.issue_id}, context.main_frame)

        refute response.isError, response_text(response)
        assert response_text(response) =~ context.issue_id
        assert response_text(response) =~ ~r/accepted/i
        {:ok, context}
      end
    end

    scenario "Main moves the issue from team A to team B" do
      given_ "main, team A holding an accepted issue, and idle team B", context do
        context = assigned_issue(context)
        scope_b = Fixtures.live_agent_scope(context.scope, label: "Issue tool destination")
        team_b = Slice.staff(%{scope: scope_b})
        {:ok, Map.merge(context, %{scope_b: scope_b, team_b: team_b.team})}
      end

      when_ "main calls the assignment tool with team B's copy", context do
        script = """
        local result, err = assign_issue_to_working_copy({
          issue_id = '#{context.issue_id}',
          working_copy_id = '#{context.scope_b.active_working_copy_id}',
          reason = 'Move this issue to the available team.'
        })
        if result == nil then error(err.message) end
        return result
        """

        {:reply, response, _} = RunScript.execute(%{script: script}, context.main_frame)
        {:ok, Map.put(context, :operation, response)}
      end

      then_ "team A is free and both members of team B hold the issue", context do
        refute context.operation.isError, response_text(context.operation)
        entries = work_entries(context)
        assert_free(entries, context.team)

        for agent <- context.team_b do
          entry = entry_for(entries, agent)
          assert entry =~ context.scope_b.active_working_copy_id
          assert entry =~ context.issue_id
          refute entry =~ "Assignment: none"
        end

        {:ok, context}
      end
    end
  end

  defp assigned_issue(context) do
    context = context |> Slice.main_copy() |> Slice.staff()
    frame = %Frame{assigns: %{current_scope: context.main_scope, agent_id: context.main.id}}

    {:reply, created, _} =
      CreateIssue.execute(
        %{
          title: "Issue whose copy main can change",
          description: "Restore a missing notification.",
          severity: "high",
          scope: "framework"
        },
        frame
      )

    false = created.isError
    issue_id = extract_issue_id!(created)
    {:reply, accepted, _} = AcceptIssue.execute(%{issue_id: issue_id}, frame)
    false = accepted.isError

    {:reply, assigned, _} =
      AssignIssueToWorkingCopy.execute(
        %{
          issue_id: issue_id,
          working_copy_id: context.scope.active_working_copy_id
        },
        frame
      )

    false = assigned.isError
    Map.merge(context, %{issue_id: issue_id, main_frame: frame})
  end

  defp work_entries(context) do
    {:reply, response, _} = ListAgentWork.execute(%{}, context.main_frame)
    refute response.isError, response_text(response)
    response |> response_text() |> String.split("Agent: ")
  end

  defp assert_free(entries, team) do
    for agent <- team do
      entry = entry_for(entries, agent)
      assert entry =~ "Assignment: none"
    end
  end

  defp entry_for(entries, agent) do
    entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
    assert entry, "The work listing must include teammate #{agent.id}"
    entry
  end
end
