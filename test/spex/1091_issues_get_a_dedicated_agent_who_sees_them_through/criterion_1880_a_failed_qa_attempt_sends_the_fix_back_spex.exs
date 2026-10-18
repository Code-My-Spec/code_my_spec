defmodule CodeMySpecSpex.Story1091.Criterion1880Spex do
  @moduledoc """
  Story 1091 — Criterion 1880: A failed QA attempt sends the fix back.

  Product's decision: completing the coding task submits the fix without
  resolving the issue. The proposed SubmitIssueQaResult MCP surface records
  an immutable attempt with issue_id, task_id, status, scenarios and issue_ids.
  A failed attempt preserves the assignment and offers coding rework.
  """

  use CodeMySpecSpex.Case
  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A failed issue QA attempt keeps the team assigned and offers rework", criterion: 1880 do
    scenario "QA rejects a submitted fix and the coder receives the issue again" do
      given_ "a team has submitted its issue fix and QA has claimed testing", context do
        context = context |> Slice.main_copy() |> Slice.staff() |> Slice.git_backed()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
        qa_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}

        created =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "An agent notification is lost",
              description: "Restore delivery so the waiting agent receives its notification.",
              severity: "high",
              scope: "framework"
            },
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = created
        issue_id = extract_issue_id!(created)

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: issue_id},
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = accepted

        assigned =
          ToolLibrary.run(
            "assign_issue_to_working_copy",
            %{
              issue_id: issue_id,
              working_copy_id: context.scope.active_working_copy_id
            },
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = assigned

        offered =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        {:ok, _} = offered
        offer_text = response_text(offered)
        true = offer_text =~ "entity_type=`issue`"
        true = offer_text =~ "entity_id=`#{issue_id}`"
        [_, fix_requirement] = Regex.run(~r/requirement_name=`([^`]+)`/, offer_text)

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: fix_requirement,
              entity_type: "issue",
              entity_id: issue_id
            },
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        {:ok, _} = started
        Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

        submitted =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: extract_task_id!(started)},
            Map.put(coder_frame.assigns, :scope, coder_frame.assigns[:current_scope])
          )

        {:ok, _} = submitted

        qa_offer =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(qa_frame.assigns, :scope, qa_frame.assigns[:current_scope])
          )

        {:ok, _} = qa_offer
        qa_offer_text = response_text(qa_offer)
        true = qa_offer_text =~ "entity_type=`issue`"
        true = qa_offer_text =~ "entity_id=`#{issue_id}`"
        [_, qa_requirement] = Regex.run(~r/requirement_name=`([^`]+)`/, qa_offer_text)

        qa_started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: qa_requirement,
              entity_type: "issue",
              entity_id: issue_id
            },
            Map.put(qa_frame.assigns, :scope, qa_frame.assigns[:current_scope])
          )

        {:ok, _} = qa_started

        before_qa =
          ToolLibrary.run(
            "get_issue",
            %{issue_id: issue_id},
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = before_qa
        true = response_text(before_qa) =~ "**Status:** accepted"

        {:ok,
         Map.merge(context, %{
           issue_id: issue_id,
           main_frame: main_frame,
           coder_frame: coder_frame,
           qa_frame: qa_frame,
           qa_task_id: extract_task_id!(qa_started),
           fix_requirement: fix_requirement
         })}
      end

      when_ "QA records its finding and submits a failing attempt", context do
        finding =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "Notification delivery still fails after the submitted fix",
              description:
                "Testing issue #{context.issue_id}: sent a notification, but the waiting agent's inbox remained empty.",
              severity: "high",
              scope: "framework"
            },
            Map.put(context.qa_frame.assigns, :scope, context.qa_frame.assigns[:current_scope])
          )

        {:ok, _} = finding
        finding_id = extract_issue_id!(finding)

        response =
          ToolLibrary.run(
            "submit_issue_qa_result",
            %{
              issue_id: context.issue_id,
              task_id: context.qa_task_id,
              status: "fail",
              scenarios: [
                %{
                  name: "The waiting agent receives its notification",
                  status: "fail",
                  observation: "Sent a notification; the waiting agent's inbox remained empty."
                }
              ],
              issue_ids: [finding_id]
            },
            Map.put(context.qa_frame.assigns, :scope, context.qa_frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :qa_response, response)}
      end

      then_ "the failed attempt is recorded and the original issue remains open", context do
        assert match?({:ok, _}, context.qa_response), response_text(context.qa_response)
        assert is_binary(extract_attempt_id!(context.qa_response))

        response =
          ToolLibrary.run(
            "get_issue",
            %{issue_id: context.issue_id},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        assert response_text(response) =~ "**Status:** accepted"
        {:ok, context}
      end

      then_ "both teammates remain bound to the same issue on their copy", context do
        response =
          ToolLibrary.run(
            "list_agent_work",
            %{},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        entries = response |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry, "The listing must retain teammate #{agent.id}"
          assert entry =~ context.scope.active_working_copy_id
          assert entry =~ context.issue_id
          refute entry =~ "Assignment: none"
        end

        {:ok, context}
      end

      then_ "the coder is offered rework for the original issue", context do
        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        text = response_text(response)
        assert text =~ "entity_type=`issue`"
        assert text =~ "entity_id=`#{context.issue_id}`"
        assert text =~ "requirement_name=`#{context.fix_requirement}`"
        {:ok, context}
      end
    end
  end
end
