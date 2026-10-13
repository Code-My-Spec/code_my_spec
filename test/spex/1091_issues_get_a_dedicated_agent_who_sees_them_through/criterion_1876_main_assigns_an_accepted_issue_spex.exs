defmodule CodeMySpecSpex.Story1091.Criterion1876Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1876 — Main assigns an accepted issue.

  AssignIssueToWorkingCopy is the required, not-yet-implemented MCP surface:
  main supplies issue_id and working_copy_id. This spec deliberately remains
  red until that surface binds the team and exposes the issue as its work.
  Existing fixture helpers establish the idle team, never its assignment.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main assigns an accepted framework issue to an idle team", criterion: 1876 do
    scenario "the copy holds the issue and offers its fix to the coder" do
      given_ "an accepted framework issue and an idle coding and QA team", context do
        context = context |> Slice.main_copy() |> Slice.staff()

        frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        {:reply, created, _frame} =
          CreateIssue.execute(
            %{
              title: "The harness drops an agent notification",
              description: "A delivered notification does not reach the waiting agent.",
              severity: "high",
              scope: "framework"
            },
            frame
          )

        false = created.isError
        issue_id = extract_issue_id!(created)
        {:reply, accepted, _frame} = AcceptIssue.execute(%{issue_id: issue_id}, frame)
        false = accepted.isError

        {:ok, Map.merge(context, %{issue_id: issue_id, main_frame: frame})}
      end

      when_ "main assigns the issue to the team's working copy", context do
        {:reply, response, _frame} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: context.issue_id,
              working_copy_id: context.scope.active_working_copy_id
            },
            context.main_frame
          )

        {:ok, Map.put(context, :assignment_response, response)}
      end

      then_ "both teammates show the issue as their copy's assignment", context do
        refute context.assignment_response.isError, response_text(context.assignment_response)

        {:reply, response, _frame} = ListAgentWork.execute(%{}, context.main_frame)
        refute response.isError, response_text(response)
        entries = response |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry, "The work listing must include teammate #{agent.id}"
          assert entry =~ context.scope.active_working_copy_id

          assert entry =~ context.issue_id,
                 "Teammate #{agent.id} must show issue #{context.issue_id} as its assignment"
        end

        {:ok, context}
      end

      then_ "the coder's next offered work is the assigned issue", context do
        coder = Enum.find(context.team, &(&1.role == :coding))
        assert coder, "The team must contain a coding agent"

        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: coder.id}
        }

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        refute response.isError, response_text(response)
        offered_work = response_text(response)
        assert offered_work =~ "entity_type=`issue`"
        assert offered_work =~ "entity_id=`#{context.issue_id}`"

        {:ok, context}
      end
    end
  end
end
