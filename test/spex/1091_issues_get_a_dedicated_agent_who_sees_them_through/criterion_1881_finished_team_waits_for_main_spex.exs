defmodule CodeMySpecSpex.Story1091.Criterion1881Spex do
  @moduledoc """
  Story 1091 — Criterion 1881: a finished team waits for main.

  Observes offers through list_offers, never the database. The new surface
  contract is a team_free offer naming the copy and completed issue, and
  a visible 'waiting for main assignment' explanation for each teammate.
  An issue completes when QA has passed it and its fix has landed through the
  promotion queue (2026-10-04); the team's wait starts there.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, AssignIssueToWorkingCopy, CreateIssue}
  alias CodeMySpec.McpServers.MainAgent.Tools.{ListAgentWork, ListOffers}
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.{Fixtures, OfferHelpers}
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
      given_ "a team has finished its issue — QA passed and its fix landed — and another issue is available",
             context do
        context =
          context
          |> a_promotable_project()
          |> an_issue_assigned_to_the_team()

        {:reply, created, _} =
          CreateIssue.execute(
            %{
              title: "Repair the issue search",
              description: "Repair the issue search",
              severity: "high",
              scope: "framework"
            },
            context.main_frame
          )

        false = created.isError
        next_issue_id = extract_issue_id!(created)

        {:reply, accepted, _} =
          AcceptIssue.execute(%{issue_id: next_issue_id}, context.main_frame)

        false = accepted.isError

        context
        |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())
        |> analyzers_are_current()
        |> qa_passes_it()
        |> the_coder_promotes_it()

        true = what_was_told(context.coder.id) =~ "landed on main"
        true = the_issue(context) =~ "**Status:** resolved"

        {:ok,
         Map.merge(context, %{
           coder_frame: OfferHelpers.agent_frame(context, context.coder.id),
           qa_frame: OfferHelpers.agent_frame(context, context.qa.id),
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
        delivered = what_was_told(context.main.id)
        assert delivered =~ context.issue_id
        assert delivered =~ context.scope.active_working_copy_id
        :ok = Fixtures.drain_background_work()

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
        assert message =~ "An agent notification is lost"
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

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"
end
