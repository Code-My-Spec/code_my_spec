defmodule CodeMySpecSpex.Story1091.Criterion1875Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1875 — Assigning an issue staffs the whole team.

  Product clarified that completing the coder's issue task submits the fix
  for QA without resolving the issue. This scenario drives that task handoff
  through MCP. Assignment and issue-scoped work are required new behavior,
  so these calls deliberately remain red until the story is implemented.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An assigned issue is carried from coding to QA by the same team", criterion: 1875 do
    scenario "both agents are bound and the fix is handed to QA after submission" do
      given_ "an unassigned working copy with a coder, QA agent, and accepted issue", context do
        context = context |> Slice.main_copy() |> Slice.staff() |> Slice.git_backed()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        {:reply, created, _frame} =
          CreateIssue.execute(
            %{
              title: "A notification is missing from the agent's inbox",
              description: "The assigned team must restore delivery and have QA verify it.",
              severity: "high",
              scope: "framework"
            },
            main_frame
          )

        false = created.isError
        issue_id = extract_issue_id!(created)
        {:reply, accepted, _frame} = AcceptIssue.execute(%{issue_id: issue_id}, main_frame)
        false = accepted.isError

        {:ok,
         Map.merge(context, %{
           issue_id: issue_id,
           main_frame: main_frame,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}},
           qa_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}
         })}
      end

      when_ "main assigns the issue to the team's copy", context do
        {:reply, response, _frame} =
          AssignIssueToWorkingCopy.execute(
            %{issue_id: context.issue_id, working_copy_id: context.scope.active_working_copy_id},
            context.main_frame
          )

        {:ok, Map.put(context, :assignment_response, response)}
      end

      then_ "both teammates show the issue as their assignment", context do
        refute context.assignment_response.isError, response_text(context.assignment_response)
        {:reply, response, _frame} = ListAgentWork.execute(%{}, context.main_frame)
        refute response.isError, response_text(response)
        entries = response |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry, "The listing must include teammate #{agent.id}"
          assert entry =~ context.scope.active_working_copy_id
          assert entry =~ context.issue_id
        end

        {:ok, context}
      end

      then_ "the coder is offered the issue's fix", context do
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, context.coder_frame)
        refute response.isError, response_text(response)
        offered = response_text(response)
        assert offered =~ "entity_type=`issue`"
        assert offered =~ "entity_id=`#{context.issue_id}`"
        [_, requirement_name] = Regex.run(~r/requirement_name=`([^`]+)`/, offered)

        {:ok, Map.put(context, :fix_requirement, requirement_name)}
      end

      when_ "the coder claims the offered fix", context do
        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: context.fix_requirement,
              entity_type: "issue",
              entity_id: context.issue_id
            },
            context.coder_frame
          )

        {:ok, Map.put(context, :start_response, response)}
      end

      then_ "the coder receives a task for the fix", context do
        refute context.start_response.isError, response_text(context.start_response)
        {:ok, Map.put(context, :fix_task_id, extract_task_id!(context.start_response))}
      end

      when_ "the coder submits the fix by completing its task", context do
        Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

        {:reply, response, _frame} =
          EvaluateTask.execute(%{task_id: context.fix_task_id}, context.coder_frame)

        {:ok, Map.put(context, :completion_response, response)}
      end

      then_ "QA is offered testing for the same issue", context do
        refute context.completion_response.isError, response_text(context.completion_response)
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, context.qa_frame)
        refute response.isError, response_text(response)
        offered = response_text(response)

        assert offered =~ "entity_type=`issue`"
        assert offered =~ "entity_id=`#{context.issue_id}`"
        assert offered =~ "requirement_name=`qa_complete`"

        {:ok, context}
      end
    end
  end
end
