defmodule CodeMySpecSpex.Story1091.Criterion1892Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1892 — Finishing a story or an issue sends main the same
  team-free offer.

  Two teams, two different ways of finishing: team A's copy promotes a
  story (the pre-existing, story-1046 mechanism); team B's copy gets a
  passing issue QA attempt (the new, story-1091 mechanism). Both must
  produce the same `team_free` offer kind to main — naming their own
  copy and what each finished (a story number, an issue id) — proving
  the two paths converge on one notice rather than main having to learn
  two.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias Anubis.Server.Frame

  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, AssignIssueToWorkingCopy, CreateIssue}
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOffers
  alias CodeMySpec.McpServers.Qa.Tools.SubmitIssueQaResult
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.McpServers.Tasks.Tools.{EvaluateTask, StartTask}
  alias CodeMySpecSpex.{Fixtures, OfferHelpers}
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Finishing a story or an issue sends main the same team-free offer",
    criterion: 1892 do
    scenario "team A finishes its story by promotion, team B finishes its issue through QA" do
      given_ "team A is bound to a story on one copy, team B is bound to an issue on another",
              context do
        # Team A: the real two-checkout promotion arrangement (story 1046). The
        # first checkout joined becomes the project's main copy, so this runs
        # before anything else claims that designation.
        context = a_promotable_project(context)
        story = a_promotable_story(context, title: "Fix the border dispute")

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_team_a"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "team A's fix"])

        team_a = for role <- ~w(coding qa), do: Fixtures.running_agent(context.scope, role: role)

        {:reply, set_active, _frame} =
          SetActiveStory.execute(
            %{story_number: story.number},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        false = set_active.isError

        # Main sits on the checkout that is already designated main — the one
        # `a_promotable_project/1` calls "running".
        running_scope = %{context.scope | active_working_copy_id: context.running.working_copy_id}
        main = Fixtures.running_agent(running_scope, role: "main")
        main_frame = %Frame{assigns: %{current_scope: running_scope, agent_id: main.id}}

        # Team B: a second, unrelated copy, bound to an accepted issue instead
        # of a story — the story-1091 mechanism.
        scope_b = Fixtures.live_agent_scope(running_scope, label: "Team B checkout")
        team_b = for role <- ~w(coding qa), do: Fixtures.running_agent(scope_b, role: role)
        coder_b = Enum.find(team_b, &(&1.role == :coding))
        qa_b = Enum.find(team_b, &(&1.role == :qa))

        {:reply, created, _frame} =
          CreateIssue.execute(
            %{
              title: "Restore the border checkpoint",
              description: "Travelers are turned back at a checkpoint that should be open.",
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
            %{issue_id: issue_id, working_copy_id: scope_b.active_working_copy_id},
            main_frame
          )

        false = assigned.isError

        fix_task = OfferHelpers.next_task(%{scope: scope_b}, coder_b.id)
        true = fix_task.entity_type == "issue"
        true = fix_task.entity_id == issue_id

        {:reply, fix_started, _frame} =
          StartTask.execute(fix_task, OfferHelpers.agent_frame(%{scope: scope_b}, coder_b.id))

        false = fix_started.isError

        {:reply, fix_submitted, _frame} =
          EvaluateTask.execute(
            %{task_id: extract_task_id!(fix_started)},
            OfferHelpers.agent_frame(%{scope: scope_b}, coder_b.id)
          )

        false = fix_submitted.isError

        qa_task = OfferHelpers.next_task(%{scope: scope_b}, qa_b.id)
        true = qa_task.entity_type == "issue"
        true = qa_task.entity_id == issue_id

        {:reply, qa_started, _frame} =
          StartTask.execute(qa_task, OfferHelpers.agent_frame(%{scope: scope_b}, qa_b.id))

        false = qa_started.isError

        {:ok,
         Map.merge(context, %{
           story: story,
           team_a: team_a,
           running_scope: running_scope,
           main: main,
           main_frame: main_frame,
           scope_b: scope_b,
           team_b: team_b,
           issue_id: issue_id,
           qa_b_task_id: extract_task_id!(qa_started),
           qa_b_frame: OfferHelpers.agent_frame(%{scope: scope_b}, qa_b.id)
         })}
      end

      when_ "team A's story is promoted and team B's issue gets a passing QA attempt and is resolved",
            context do
        context_a = analyzers_are_current(context)
        promote_response = promote(context_a, context.story.number)

        {:reply, qa_response, _frame} =
          SubmitIssueQaResult.execute(
            %{
              issue_id: context.issue_id,
              task_id: context.qa_b_task_id,
              status: "pass",
              scenarios: [
                %{
                  name: "The checkpoint reopens",
                  status: "pass",
                  observation: "Travelers were able to cross after the fix."
                }
              ],
              issue_ids: []
            },
            context.qa_b_frame
          )

        {:ok,
         Map.merge(context, %{promote_response: promote_response, qa_response: qa_response})}
      end

      then_ "both finishing actions are accepted", context do
        refute context.promote_response.isError, response_text(context.promote_response)
        refute context.qa_response.isError, response_text(context.qa_response)
        {:ok, context}
      end

      then_ "main receives one team-free offer per team, both the same kind, each naming its copy and what it finished",
            context do
        {:reply, response, _frame} =
          ListOffers.execute(%{agent_id: context.main.id, kind: "team_free"}, context.main_frame)

        refute response.isError, response_text(response)
        offers = OfferHelpers.parse(response_text(response))

        assert length(offers) == 2,
               "expected one team-free offer per team (two), got: #{response_text(response)}"

        assert Enum.all?(offers, &(&1.kind == "team_free")),
               "both offers must be the same kind, team_free, regardless of what finished: " <>
                 "#{response_text(response)}"

        story_number = Integer.to_string(context.story.number)

        story_offer = Enum.find(offers, &Enum.any?(&1.messages, fn m -> m =~ story_number end))
        issue_offer = Enum.find(offers, &Enum.any?(&1.messages, fn m -> m =~ context.issue_id end))

        assert story_offer,
               "no team-free offer named story #{story_number}: #{response_text(response)}"

        assert issue_offer,
               "no team-free offer named issue #{context.issue_id}: #{response_text(response)}"

        assert Enum.any?(story_offer.messages, &(&1 =~ context.scope.active_working_copy_id)),
               "the story offer should name team A's own copy: #{inspect(story_offer.messages)}"

        assert Enum.any?(issue_offer.messages, &(&1 =~ context.scope_b.active_working_copy_id)),
               "the issue offer should name team B's own copy: #{inspect(issue_offer.messages)}"

        {:ok, context}
      end
    end
  end
end
