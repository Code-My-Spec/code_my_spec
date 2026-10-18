defmodule CodeMySpecSpex.Story1091.Criterion2081Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 2081 — Coding and QA work independently across an assigned
  issue bag.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coding and QA work independently across an assigned issue bag", criterion: 2081 do
    scenario "QA claims the submitted issue while coding claims the one still waiting" do
      given_ "the bag holds issue A, submitted to QA, and issue B, still awaiting coding", ctx do
        ctx = ctx |> a_promotable_project() |> an_issue_assigned_to_the_team()

        created =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "A second, unrelated defect",
              description: "Still waiting on a fix.",
              severity: "high",
              scope: "framework"
            },
            Map.put(ctx.main_frame.assigns, :scope, ctx.main_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, created)
        issue_b = extract_issue_id!(created)

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: issue_b},
            Map.put(ctx.main_frame.assigns, :scope, ctx.main_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, accepted)

        assigned =
          ToolLibrary.run(
            "assign_issue_to_working_copy",
            %{issue_id: issue_b, working_copy_id: ctx.scope.active_working_copy_id},
            Map.put(ctx.main_frame.assigns, :scope, ctx.main_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, assigned)

        ctx =
          the_coder_fixes_it(
            ctx,
            "lib/broken_oaths/diplomacy/first.ex",
            "defmodule BrokenOaths.Diplomacy.First do\n  def done, do: :ok\nend\n"
          )

        {:ok, Map.put(ctx, :issue_b, issue_b)}
      end

      when_ "coding and QA each ask for their next eligible work", ctx do
        qa_offer =
          ToolLibrary.run("get_next_requirement", %{}, %{scope: ctx.scope, agent_id: ctx.qa.id})

        coder_offer =
          ToolLibrary.run("get_next_requirement", %{}, %{scope: ctx.scope, agent_id: ctx.coder.id})

        assert match?({:ok, _}, qa_offer)
        assert match?({:ok, _}, coder_offer)
        {:ok, Map.merge(ctx, %{qa_offer: qa_offer, coder_offer: coder_offer})}
      end

      then_ "QA is offered issue A and coding is offered issue B, independently", ctx do
        qa_text = response_text(ctx.qa_offer)
        assert qa_text =~ "entity_id=`#{ctx.issue_id}`"
        assert qa_text =~ "requirement_name=`qa_complete`"
        refute qa_text =~ "entity_id=`#{ctx.issue_b}`"

        coder_text = response_text(ctx.coder_offer)
        assert coder_text =~ "entity_id=`#{ctx.issue_b}`"
        assert coder_text =~ "requirement_name=`fix_issue`"
        refute coder_text =~ "entity_id=`#{ctx.issue_id}`"

        {:ok, ctx}
      end
    end
  end
end
