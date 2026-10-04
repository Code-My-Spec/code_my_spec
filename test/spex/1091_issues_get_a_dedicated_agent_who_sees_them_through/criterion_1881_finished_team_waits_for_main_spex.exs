defmodule CodeMySpecSpex.Story1091.Criterion1881Spex do
  @moduledoc """
  Story 1091 — Criterion 1881: a finished team waits for main.

  Observes offers through list_offers, never the database. The new surface
  contract is a team_free offer naming the copy and completed issue, and
  a visible 'waiting for main assignment' explanation for each teammate.
  Issue completion uses the issue QA submission contract agreed with product.
  """
  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame

  alias CodeMySpec.McpServers.Issues.Tools.{
    AcceptIssue,
    AssignIssueToWorkingCopy,
    CreateIssue,
    GetIssue
  }

  alias CodeMySpec.McpServers.MainAgent.Tools.{ListAgentWork, ListOffers}
  alias CodeMySpec.McpServers.Qa.Tools.SubmitIssueQaResult
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.{EvaluateTask, StartTask}
  alias CodeMySpecSpex.{Fixtures, OfferHelpers}
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "A finished team waits visibly while main receives one team-free offer", criterion: 1881 do
    scenario "Repeated work requests do not pick another issue or duplicate main's offer" do
      given_ "a team has finished its issue through passing QA and another issue is available",
             context do
        context = context |> Slice.main_copy() |> Slice.staff()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        coder_frame = OfferHelpers.agent_frame(context, coder.id)
        qa_frame = OfferHelpers.agent_frame(context, qa.id)

        issue_ids =
          for title <- ["Repair notification delivery", "Repair the issue search"] do
            {:reply, created, _} =
              CreateIssue.execute(
                %{title: title, description: title, severity: "high", scope: "framework"},
                main_frame
              )

            false = created.isError
            id = extract_issue_id!(created)
            {:reply, accepted, _} = AcceptIssue.execute(%{issue_id: id}, main_frame)
            false = accepted.isError
            id
          end

        [issue_id, next_issue_id] = issue_ids

        {:reply, assigned, _} =
          AssignIssueToWorkingCopy.execute(
            %{issue_id: issue_id, working_copy_id: context.scope.active_working_copy_id},
            main_frame
          )

        false = assigned.isError

        coding_args = OfferHelpers.next_task(context, coder.id)
        true = coding_args.entity_type == "issue"
        true = coding_args.entity_id == issue_id
        {:reply, coding_started, _} = StartTask.execute(coding_args, coder_frame)
        false = coding_started.isError

        {:reply, submitted, _} =
          EvaluateTask.execute(%{task_id: extract_task_id!(coding_started)}, coder_frame)

        false = submitted.isError

        qa_args = OfferHelpers.next_task(context, qa.id)
        true = qa_args.entity_type == "issue"
        true = qa_args.entity_id == issue_id
        {:reply, qa_started, _} = StartTask.execute(qa_args, qa_frame)
        false = qa_started.isError

        {:reply, passed, _} =
          SubmitIssueQaResult.execute(
            %{
              issue_id: issue_id,
              task_id: extract_task_id!(qa_started),
              status: "pass",
              issue_ids: [],
              scenarios: [
                %{
                  name: "Notification delivery",
                  status: "pass",
                  observation: "The waiting agent received its notification."
                }
              ]
            },
            qa_frame
          )

        false = passed.isError
        {:reply, finished, _} = GetIssue.execute(%{issue_id: issue_id}, main_frame)
        false = finished.isError
        true = response_text(finished) =~ "**Status:** resolved"

        {:ok,
         Map.merge(context, %{
           main_frame: main_frame,
           coder_frame: coder_frame,
           qa_frame: qa_frame,
           issue_id: issue_id,
           next_issue_id: next_issue_id
         })}
      end

      when_ "both teammates ask for work twice without a new main assignment", context do
        responses =
          for _round <- 1..2, frame <- [context.coder_frame, context.qa_frame] do
            {:reply, response, _} = GetNextRequirement.execute(%{}, frame)
            response
          end

        {:ok, Map.put(context, :waiting_responses, responses)}
      end

      then_ "neither teammate is offered work and each visibly waits for main", context do
        for response <- context.waiting_responses do
          refute response.isError, response_text(response)
          text = response_text(response)
          assert String.downcase(text) =~ "waiting for main assignment"
          refute text =~ "requirement_name=`"
        end

        {:reply, work, _} = ListAgentWork.execute(%{}, context.main_frame)
        refute work.isError, response_text(work)
        entries = work |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry
          assert entry =~ context.scope.active_working_copy_id
          assert String.downcase(entry) =~ "waiting for main assignment"
        end

        {:ok, context}
      end

      then_ "main has exactly one delivered team-free offer naming the team and its finished issue",
            context do
        {:reply, response, _} =
          ListOffers.execute(
            %{agent_id: context.main.id, kind: "team_free"},
            context.main_frame
          )

        refute response.isError, response_text(response)
        assert [offer] = OfferHelpers.parse(response_text(response))
        assert offer.kind == "team_free"
        refute offer.status == "undelivered"
        assert offer.messages != []
        message = Enum.join(offer.messages, "\n")
        assert message =~ context.scope.active_working_copy_id
        assert message =~ context.issue_id
        assert message =~ "Repair notification delivery"
        {:ok, context}
      end

      when_ "main assigns the next issue to this team", context do
        {:reply, response, _} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: context.next_issue_id,
              working_copy_id: context.scope.active_working_copy_id
            },
            context.main_frame
          )

        {:ok, Map.put(context, :next_assignment, response)}
      end

      then_ "the coder can take the newly assigned issue and the visible wait ends", context do
        refute context.next_assignment.isError, response_text(context.next_assignment)
        {:reply, response, _} = GetNextRequirement.execute(%{}, context.coder_frame)
        refute response.isError, response_text(response)
        assert response_text(response) =~ "entity_type=`issue`"
        assert response_text(response) =~ "entity_id=`#{context.next_issue_id}`"
        {:reply, work, _} = ListAgentWork.execute(%{}, context.main_frame)
        refute work.isError, response_text(work)
        entries = work |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry
          assert entry =~ context.next_issue_id
          refute String.downcase(entry) =~ "waiting for main assignment"
        end

        {:ok, context}
      end
    end
  end
end
