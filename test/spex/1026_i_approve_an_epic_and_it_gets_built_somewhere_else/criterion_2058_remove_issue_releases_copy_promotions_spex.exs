defmodule CodeMySpecSpex.Story1026.Criterion2058Spex do
  @moduledoc """
  Story 1026 — Removing an issue releases its former copy's promotions.
  The issue remains unresolved: reassignment is not resolution. Real promotion
  requests before and after removal distinguish release from a cosmetic edit.
  Existing promotion fixtures supply clean analyzer evidence; separate promotion
  specs cover the harness producing that evidence.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.IssuePromotionHelpers, as: Issue
  alias CodeMySpecSpex.PromotionHelpers, as: Promotion
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Taking an issue off a copy releases that copy's promotions", criterion: 2058 do
    scenario "An unresolved issue stops holding its former copy's clean work" do
      given_ "a clean committed copy carrying an accepted unresolved issue", context do
        context =
          context
          |> Promotion.a_promotable_project()
          |> Issue.an_issue_assigned_to_the_team()
          |> Promotion.with_work_on_the_copy()
          |> Promotion.analyzers_are_current()

        story = Promotion.a_promotable_story(context)

        {:ok, issue_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/issues/#{context.issue_id}")

        {:ok, Map.merge(context, %{promotable_story: story, issue_view: issue_view})}
      end

      when_ "the coder attempts to promote while the issue is still assigned", context do
        response = Promotion.promote_from(candidate(context), context.promotable_story.number)
        {:ok, Map.put(context, :before_removal, response)}
      end

      then_ "the promotion is refused and names the assigned issue", context do
        assert context.before_removal.isError
        assert response_text(context.before_removal) =~ context.issue_id
        {:ok, context}
      end

      when_ "I take the issue off its copy without resolving it", context do
        context.issue_view
        |> element("[data-test='unassign-issue-from-working-copy']")
        |> render_click()

        {:ok, context}
      end

      then_ "the issue remains accepted and unresolved", context do
        issue_text = Issue.the_issue(context)
        assert issue_text =~ context.issue_id
        assert issue_text =~ ~r/accepted/i
        {:ok, context}
      end

      when_ "the coder promotes the same committed work again", context do
        response = Promotion.promote_from(candidate(context), context.promotable_story.number)
        {:ok, Map.put(context, :after_removal, response)}
      end

      then_ "the promotion enters the queue instead of waiting on the removed issue", context do
        refute context.after_removal.isError, response_text(context.after_removal)
        assert response_text(context.after_removal) =~ "Queued for promotion"
        {:ok, context}
      end
    end
  end

  defp candidate(context),
    do: %{scope: context.scope, agent_id: context.coder.id}
end
