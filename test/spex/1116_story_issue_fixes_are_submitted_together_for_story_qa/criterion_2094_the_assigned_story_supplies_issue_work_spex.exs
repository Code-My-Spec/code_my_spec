defmodule CodeMySpecSpex.Story1116.Criterion2094Spex do
  @moduledoc "The assigned story supplies the issue work."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The assigned story supplies the issue work", criterion: 2094 do
    scenario "The assigned story supplies the issue work" do
      given_ "a story team with the relevant issue work", context do
        context = Bag.team(context)
        context = Bag.issue(context, :a)
        context = Bag.issue(context, :b)
        context = Bag.issue(context, :project_issue, %{story_id: nil})
        context = Bag.other_story_issue(context, :other_issue)
        {:ok, context}
      end

      when_ "coding asks for work", context do
        {:ok, Map.put(context, :offered, Bag.next(context, :coding))}
      end

      then_ "the story workflow reflects the team's issue submissions", context do
        assert context.offered =~ "entity_id=`#{context.a.id}`" or
                 context.offered =~ "entity_id=`#{context.b.id}`"

        assert context.offered =~ "Remaining: 1"
        refute context.offered =~ "entity_id=`#{context.project_issue.id}`"
        refute context.offered =~ "entity_id=`#{context.other_issue.id}`"
        refute context.offered =~ "requirement_name=`assigned`"
        refute context.offered =~ "FixStoryIssues"
        {:ok, context}
      end

      when_ "coding chooses the other fix from its story bag", context do
        selected =
          Enum.find([:a, :b], fn key ->
            not String.contains?(context.offered, "entity_id=`#{Map.fetch!(context, key).id}`")
          end)

        {:ok, Map.merge(context, %{selected: selected, prompt: Bag.start_fix(context, selected)})}
      end

      then_ "the other fix can be claimed without separate issue assignment", context do
        issue = Map.fetch!(context, context.selected)
        assert context.prompt =~ issue.id
        assert context.prompt =~ "submit_story_issue"
        {:ok, context}
      end

      when_ "coding submits the chosen fix and finishes its task", context do
        context = Bag.submit(context, context.selected)

        Slice.call(context, "evaluate_task", %{task_id: extract_task_id!(context.prompt)}, %{
          agent_id: context.coding.id
        })

        {:ok, context}
      end

      when_ "coding claims the remaining fix without waiting for QA", context do
        [remaining] = [:a, :b] -- [context.selected]

        {:ok,
         Map.merge(context, %{
           remaining: remaining,
           next_prompt: Bag.start_fix(context, remaining)
         })}
      end

      then_ "both fixes were claimable under the story assignment", context do
        assert context.next_prompt =~ Map.fetch!(context, context.remaining).id
        assert context.next_prompt =~ "submit_story_issue"
        {:ok, context}
      end
    end
  end
end
