defmodule CodeMySpecSpex.Story1091.Criterion2081Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 2081 — Coding and QA work independently across an assigned
  issue bag.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Coding and QA work independently across an assigned issue bag", criterion: 2081 do
    scenario "QA claims the submitted issue while coding claims the one still waiting" do
      given_ "the bag holds issue A, submitted to QA, and issue B, still awaiting coding", ctx do
        ctx = ctx |> a_promotable_project() |> an_issue_assigned_to_the_team()

        {:reply, created, _frame} =
          CreateIssue.execute(
            %{
              title: "A second, unrelated defect",
              description: "Still waiting on a fix.",
              severity: "high",
              scope: "framework"
            },
            ctx.main_frame
          )

        refute created.isError
        issue_b = extract_issue_id!(created)
        {:reply, accepted, _frame} = AcceptIssue.execute(%{issue_id: issue_b}, ctx.main_frame)
        refute accepted.isError

        {:reply, assigned, _frame} =
          AssignIssueToWorkingCopy.execute(
            %{issue_id: issue_b, working_copy_id: ctx.scope.active_working_copy_id},
            ctx.main_frame
          )

        refute assigned.isError

        ctx =
          the_coder_fixes_it(
            ctx,
            "lib/broken_oaths/diplomacy/first.ex",
            "defmodule BrokenOaths.Diplomacy.First do\n  def done, do: :ok\nend\n"
          )

        {:ok, Map.put(ctx, :issue_b, issue_b)}
      end

      when_ "coding and QA each ask for their next eligible work", ctx do
        {:reply, qa_offer, _frame} =
          GetNextRequirement.execute(%{}, %Frame{
            assigns: %{current_scope: ctx.scope, agent_id: ctx.qa.id}
          })

        {:reply, coder_offer, _frame} =
          GetNextRequirement.execute(%{}, %Frame{
            assigns: %{current_scope: ctx.scope, agent_id: ctx.coder.id}
          })

        refute qa_offer.isError
        refute coder_offer.isError
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
