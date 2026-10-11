defmodule CodeMySpecSpex.Story1091.Criterion1892Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1892 — Finishing a story or an issue sends main the same
  team-free offer.

  Two teams, two kinds of work: team A's copy promotes a story; team B's copy
  promotes the fix for its issue once QA has passed it. Both finish the same
  way now — their work lands through the promotion queue (2026-10-04) — and
  both must produce the same `team_free` offer kind to main, naming their own
  copy and what each finished (a story number, an issue id), so main learns one
  notice rather than two.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOffers
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.{Fixtures, OfferHelpers}
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Finishing a story or an issue sends main the same team-free offer",
    criterion: 1892 do
    scenario "team A lands its story, team B lands its issue's fix" do
      given_ "team A is bound to a story on one copy, team B is bound to an issue on another",
             context do
        context =
          context
          |> a_promotable_project()
          |> another_candidate(:team_a)
          |> an_issue_assigned_to_the_team()

        commit_work(
          context,
          context.team_a.root,
          "lib/broken_oaths/diplomacy/border.ex",
          border()
        )

        story_context = %{context | scope: context.team_a.scope, agent_root: context.team_a.root}
        story = a_promotable_story(story_context, title: "Fix the border dispute")
        _qa = Fixtures.running_agent(context.team_a.scope, role: "qa")

        {:reply, set_active, _frame} =
          SetActiveStory.execute(
            %{story_number: story.number},
            %Frame{assigns: %{current_scope: context.team_a.scope}}
          )

        refute set_active.isError, response_text(set_active)
        its_analyzers_are_current(context, context.team_a)

        {:ok, Map.put(context, :story, story)}
      end

      when_ "team A's story lands", context do
        response = promote_from(context.team_a, context.story.number)
        assert what_was_told(context.team_a.agent_id) =~ "landed on main"

        {:reply, next, _} =
          GetNextRequirement.execute(
            %{},
            %Frame{
              assigns: %{current_scope: context.team_a.scope, agent_id: context.team_a.agent_id}
            }
          )

        refute next.isError
        assert String.downcase(response_text(next)) =~ "waiting for main assignment"
        {:ok, Map.put(context, :promote_response, response)}
      end

      when_ "team B's fix passes QA and lands", context do
        context
        |> the_coder_fixes_it("lib/broken_oaths/diplomacy/checkpoint.ex", checkpoint())
        |> analyzers_are_current()
        |> qa_passes_it()
        |> the_coder_promotes_it()

        # Behind main now that team A's story has landed: gated with it beneath.
        the_gate_answers(context)
        assert what_was_told(context.coder.id) =~ "landed on main"
        {:ok, context}
      end

      then_ "main receives one team-free offer per team, both the same kind, each naming its copy and what it finished",
            context do
        notices = [what_was_told(context.main.id), what_was_told(context.main.id)]
        assert Enum.any?(notices, &(&1 =~ "story #{context.story.number} ("))
        assert Enum.any?(notices, &(&1 =~ context.issue_id))
        :ok = Fixtures.drain_background_work()

        {:reply, response, _frame} =
          ListOffers.execute(%{agent_id: context.main.id, kind: "team_free"}, context.main_frame)

        refute response.isError, response_text(response)
        offers = OfferHelpers.parse(response_text(response))

        assert length(offers) == 2,
               "expected one team-free offer per team (two), got: #{response_text(response)}"

        assert Enum.all?(offers, &(&1.kind == "team_free")),
               "both offers must be the same kind, team_free, regardless of what finished: " <>
                 "#{response_text(response)}"

        story_marker = "story #{context.story.number} ("

        story_offer = Enum.find(offers, &Enum.any?(&1.messages, fn m -> m =~ story_marker end))

        issue_offer =
          Enum.find(offers, &Enum.any?(&1.messages, fn m -> m =~ context.issue_id end))

        assert story_offer,
               "no team-free offer named story #{context.story.number}: #{response_text(response)}"

        assert issue_offer,
               "no team-free offer named issue #{context.issue_id}: #{response_text(response)}"

        assert Enum.any?(story_offer.messages, &(&1 =~ context.team_a.working_copy_id)),
               "the story offer should name team A's own copy: #{inspect(story_offer.messages)}"

        assert Enum.any?(issue_offer.messages, &(&1 =~ context.scope.active_working_copy_id)),
               "the issue offer should name team B's own copy: #{inspect(issue_offer.messages)}"

        {:ok, context}
      end
    end
  end

  defp border,
    do: "defmodule BrokenOaths.Diplomacy.Border do\n  def settle, do: :settled\nend\n"

  defp checkpoint,
    do: "defmodule BrokenOaths.Diplomacy.Checkpoint do\n  def open, do: :open\nend\n"
end
