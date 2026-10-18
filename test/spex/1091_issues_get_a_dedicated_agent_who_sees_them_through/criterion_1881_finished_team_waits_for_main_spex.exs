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

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.{Fixtures, OfferHelpers}
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
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

        created =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "Repair the issue search",
              description: "Repair the issue search",
              severity: "high",
              scope: "framework"
            },
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        {:ok, _} = created
        next_issue_id = extract_issue_id!(created)

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: next_issue_id},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        {:ok, _} = accepted

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
            response =
              ToolLibrary.run(
                "get_next_requirement",
                %{},
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            response
          end

        {:ok, Map.put(context, :waiting_responses, responses)}
      end

      then_ "neither teammate is offered work and each visibly waits for main", context do
        for response <- context.waiting_responses do
          assert match?({:ok, _}, response), response_text(response)
          text = response_text(response)
          assert String.downcase(text) =~ "waiting for main assignment"
          refute text =~ "requirement_name=`"
        end

        work =
          ToolLibrary.run(
            "list_agent_work",
            %{},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, work), response_text(work)
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

        response =
          ToolLibrary.run(
            "list_offers",
            %{agent_id: context.main.id, kind: "team_free"},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
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
        response =
          ToolLibrary.run(
            "assign_issue_to_working_copy",
            %{
              issue_id: context.next_issue_id,
              working_copy_id: context.scope.active_working_copy_id
            },
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :next_assignment, response)}
      end

      then_ "the coder can take the newly assigned issue and the visible wait ends", context do
        assert match?({:ok, _}, context.next_assignment), response_text(context.next_assignment)

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
        assert response_text(response) =~ "entity_type=`issue`"
        assert response_text(response) =~ "entity_id=`#{context.next_issue_id}`"

        work =
          ToolLibrary.run(
            "list_agent_work",
            %{},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, work), response_text(work)
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
