defmodule CodeMySpecSpex.Story561.Criterion3607Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3607 — The working copy stays on its active story while another role finishes
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The working copy stays on its active story while another role finishes" do
    scenario "The working copy stays on its active story while another role finishes" do
      given_ "a story whose remaining work belongs to another role", context do
        context =
          context
          |> CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story()
          |> Slice.activate()
          |> Slice.waiting()

        coding = CodeMySpecSpex.Fixtures.running_agent(context.scope, role: "coding")
        qa = CodeMySpecSpex.Fixtures.running_agent(context.scope, role: "qa")
        {:ok, Map.merge(context, %{coding: coding, qa: qa})}
      end

      when_ "the agent asks what to work on", context do
        {:ok,
         Map.merge(context, %{
           coding_answer: Slice.next(context, %{agent_id: context.coding.id}),
           answer: Slice.next(context, %{agent_id: context.qa.id})
         })}
      end

      then_ "this copy stays on the same story rather than moving on", context do
        Slice.assert_active(context.answer, context, "ready")
        assert context.answer =~ "qa_complete"
        assert context.coding_answer =~ "# Story #{context.story.id}:"
        refute Slice.offered?(context.coding_answer, context.waiting.id)
        refute context.coding_answer =~ "Status: complete"
        {:ok, context}
      end
    end
  end
end
