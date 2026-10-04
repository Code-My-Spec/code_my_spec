defmodule CodeMySpecSpex.Story1091.Criterion1879Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1879 — QA passes, then the issue resolves and the team is freed.

  Product's decision: the coder completes its task without resolving the
  issue; a passing immutable issue QA attempt resolves it. The proposed
  SubmitIssueQaResult MCP surface takes issue_id, task_id, status, scenarios
  and issue_ids, following the story QA submission contract. The work listing
  exposes an unassigned team member with `Assignment: none`. These are
  required surface contracts for the implementation, not mocks.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame

  alias CodeMySpec.McpServers.Issues.Tools.{
    AcceptIssue,
    AssignIssueToWorkingCopy,
    CreateIssue,
    GetIssue
  }

  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Qa.Tools.SubmitIssueQaResult
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.{EvaluateTask, StartTask}
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A passing issue QA attempt resolves the issue and frees its team", criterion: 1879 do
    scenario "QA verifies the submitted fix and the team becomes unassigned" do
      given_ "a coder has submitted a fix and its teammate has claimed issue QA", context do
        context = context |> Slice.main_copy() |> Slice.staff()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
        qa_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}

        {:reply, created, _frame} =
          CreateIssue.execute(
            %{
              title: "An agent notification is lost",
              description: "Restore delivery so the waiting agent receives its notification.",
              severity: "high",
              scope: "framework"
            },
            main_frame
          )

        false = created.isError
        issue_id = extract_issue_id!(created)

        {:reply, accepted, _frame} = AcceptIssue.execute(%{issue_id: issue_id}, main_frame)
        false = accepted.isError

        {:reply, assigned, _frame} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: issue_id,
              working_copy_id: context.scope.active_working_copy_id
            },
            main_frame
          )

        false = assigned.isError

        {:reply, offered, _frame} = GetNextRequirement.execute(%{}, coder_frame)
        false = offered.isError
        offer_text = response_text(offered)
        true = offer_text =~ "entity_type=`issue`"
        true = offer_text =~ "entity_id=`#{issue_id}`"
        [_, fix_requirement] = Regex.run(~r/requirement_name=`([^`]+)`/, offer_text)

        {:reply, started, _frame} =
          StartTask.execute(
            %{
              requirement_name: fix_requirement,
              entity_type: "issue",
              entity_id: issue_id
            },
            coder_frame
          )

        false = started.isError

        {:reply, submitted, _frame} =
          EvaluateTask.execute(
            %{
              task_id: extract_task_id!(started)
            },
            coder_frame
          )

        false = submitted.isError

        {:reply, qa_offer, _frame} = GetNextRequirement.execute(%{}, qa_frame)
        false = qa_offer.isError
        qa_offer_text = response_text(qa_offer)
        true = qa_offer_text =~ "entity_type=`issue`"
        true = qa_offer_text =~ "entity_id=`#{issue_id}`"
        [_, qa_requirement] = Regex.run(~r/requirement_name=`([^`]+)`/, qa_offer_text)

        {:reply, qa_started, _frame} =
          StartTask.execute(
            %{
              requirement_name: qa_requirement,
              entity_type: "issue",
              entity_id: issue_id
            },
            qa_frame
          )

        false = qa_started.isError

        {:reply, before_qa, _frame} = GetIssue.execute(%{issue_id: issue_id}, main_frame)
        false = before_qa.isError
        false = response_text(before_qa) =~ "**Status:** resolved"

        {:ok,
         Map.merge(context, %{
           issue_id: issue_id,
           main_frame: main_frame,
           qa_frame: qa_frame,
           qa_task_id: extract_task_id!(qa_started)
         })}
      end

      when_ "QA submits a passing attempt on the issue", context do
        {:reply, response, _frame} =
          SubmitIssueQaResult.execute(
            %{
              issue_id: context.issue_id,
              task_id: context.qa_task_id,
              status: "pass",
              scenarios: [
                %{
                  name: "The waiting agent receives its notification",
                  status: "pass",
                  observation:
                    "Delivered a notification and observed it in the waiting agent's inbox."
                }
              ],
              issue_ids: []
            },
            context.qa_frame
          )

        {:ok, Map.put(context, :qa_response, response)}
      end

      then_ "the attempt is recorded and the issue is resolved", context do
        refute context.qa_response.isError, response_text(context.qa_response)
        assert is_binary(extract_attempt_id!(context.qa_response))

        {:reply, response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, context.main_frame)

        refute response.isError, response_text(response)
        assert response_text(response) =~ "**Status:** resolved"
        {:ok, context}
      end

      then_ "both teammates are free for main to assign their next work", context do
        {:reply, response, _frame} = ListAgentWork.execute(%{}, context.main_frame)
        refute response.isError, response_text(response)
        entries = response |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry, "The listing must retain teammate #{agent.id}"
          assert entry =~ context.scope.active_working_copy_id
          assert entry =~ "Assignment: none"
        end

        {:ok, context}
      end
    end
  end
end
