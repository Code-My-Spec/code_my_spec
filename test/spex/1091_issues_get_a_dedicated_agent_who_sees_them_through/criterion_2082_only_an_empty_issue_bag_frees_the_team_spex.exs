defmodule CodeMySpecSpex.Story1091.Criterion2082Spex do
  @moduledoc "The final landed, QA-passed issue empties the bag and delivers Main's handoff."
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.OfferHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Only an empty issue bag frees the team", criterion: 2082 do
    scenario "Two issues finish separately and Main receives only the final handoff" do
      given_ "a team has two accepted project issues in its bag", ctx do
        ctx = ctx |> a_promotable_project() |> an_issue_assigned_to_the_team()

        {:reply, created, _} =
          CreateIssue.execute(
            %{
              title: "Repair the second notification",
              description: "Preserve the second assignment",
              severity: "high",
              scope: "framework"
            },
            ctx.main_frame
          )

        refute created.isError
        second = extract_issue_id!(created)
        {:reply, accepted, _} = AcceptIssue.execute(%{issue_id: second}, ctx.main_frame)
        refute accepted.isError

        {:reply, assigned, _} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: second,
              working_copy_id: ctx.scope.active_working_copy_id
            },
            ctx.main_frame
          )

        refute assigned.isError
        {:ok, Map.put(ctx, :second_issue_id, second)}
      end

      when_ "both fixes pass QA and the first lands", ctx do
        second = %{ctx | issue_id: ctx.second_issue_id}
        ctx |> fix("first") |> qa_passes_it()
        second |> fix("second") |> qa_passes_it()
        ctx |> analyzers_are_current() |> the_coder_promotes_it()
        assert what_was_told(ctx.coder.id) =~ "landed on main"
        {:ok, ctx}
      end

      then_ "only the remaining issue stays assigned and no team-free offer is sent", ctx do
        bag = bag_text(ctx)
        refute bag =~ ctx.issue_id
        assert bag =~ ctx.second_issue_id
        assert OfferHelpers.offers(ctx, ctx.main.id, %{kind: "team_free"}) == []
        refute the_team_is_free?(ctx)
        {:ok, ctx}
      end

      when_ "the remaining issue lands", ctx do
        %{ctx | issue_id: ctx.second_issue_id}
        |> analyzers_are_current()
        |> the_coder_promotes_it()

        assert what_was_told(ctx.coder.id) =~ "landed on main"
        {:ok, ctx}
      end

      then_ "the bag and active issue assignments are empty and Main receives one handoff", ctx do
        bag = bag_text(ctx)
        refute bag =~ ctx.issue_id
        refute bag =~ ctx.second_issue_id
        assert the_team_is_free?(ctx)
        message = what_was_told(ctx.main.id)
        assert message =~ ctx.second_issue_id
        assert message =~ ctx.scope.active_working_copy_id
        :ok = Fixtures.drain_background_work()
        assert [offer] = OfferHelpers.offers(ctx, ctx.main.id, %{kind: "team_free"})
        refute offer.status == "undelivered"
        assert the_issue(ctx) =~ "**Status:** resolved"
        assert the_issue(%{ctx | issue_id: ctx.second_issue_id}) =~ "**Status:** resolved"
        {:ok, ctx}
      end
    end
  end

  # A QA-passed fix no longer holds the bag; one still awaiting its fix or QA
  # does, so both pass QA before either promotes.
  defp fix(ctx, name) do
    ctx
    |> the_coder_fixes_it(
      "lib/broken_oaths/diplomacy/#{name}.ex",
      "defmodule BrokenOaths.Diplomacy.#{String.capitalize(name)} do\n  def done, do: :ok\nend\n"
    )
    |> analyzers_are_current()
  end

  defp bag_text(ctx) do
    {:reply, response, _} =
      ListIssues.execute(
        %{
          working_copy_id: ctx.scope.active_working_copy_id,
          status: "all",
          severity: "all"
        },
        ctx.main_frame
      )

    refute response.isError
    response_text(response)
  end
end
