defmodule CodeMySpecSpex.Story1026.Criterion2059Spex do
  @moduledoc """
  Story 1026 — Only the copy currently holding an issue waits on it.
  Two committed candidates have clean analyzer evidence supplied by existing
  promotion fixtures. Moving the unresolved issue uses its UI; subsequent
  promotion tool replies prove which copy carries the blocker.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.IssuePromotionHelpers, as: Issue
  alias CodeMySpecSpex.PromotionHelpers, as: Promotion
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Moving an issue moves the promotion blocker to its new copy", criterion: 2059 do
    scenario "Copy A is released while copy B waits on the same unresolved issue" do
      given_ "two clean committed copies and an unresolved issue assigned to copy A", context do
        context =
          context
          |> Promotion.a_promotable_project()
          |> Issue.an_issue_assigned_to_the_team()
          |> Promotion.with_work_on_the_copy()
          |> Promotion.another_candidate(:destination)

        destination_team = Slice.staff(%{scope: context.destination.scope})
        destination_coder = Enum.find(destination_team.team, &(&1.role == :coding))

        Promotion.commit_work(
          context,
          context.destination.root,
          "lib/destination_work.ex",
          "defmodule DestinationWork do\nend\n"
        )

        story_a = Promotion.a_promotable_story(context, title: "Copy A finished work")

        story_b =
          Promotion.a_promotable_story(
            %{context | scope: context.destination.scope, agent_root: context.destination.root},
            title: "Copy B finished work"
          )

        context = Promotion.analyzers_are_current(context)
        context = Promotion.its_analyzers_are_current(context, context.destination)

        {:ok, issue_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/issues/#{context.issue_id}")

        {:ok,
         Map.merge(context, %{
           issue_view: issue_view,
           story_a: story_a,
           story_b: story_b,
           destination_coder: destination_coder
         })}
      end

      when_ "I move the issue from copy A to copy B", context do
        context.issue_view
        |> form("[data-test='issue-assignment-form']", %{
          "working_copy_id" => context.destination.working_copy_id
        })
        |> render_submit()

        {:ok, context}
      end

      then_ "the issue remains unresolved after the move", context do
        text = Issue.the_issue(context)
        assert text =~ context.issue_id
        assert text =~ ~r/accepted/i
        {:ok, context}
      end

      when_ "both copies request promotion of their clean work", context do
        old_response =
          Promotion.promote_from(
            %{scope: context.scope, agent_id: context.coder.id},
            context.story_a.number
          )

        new_response =
          Promotion.promote_from(
            %{scope: context.destination.scope, agent_id: context.destination_coder.id},
            context.story_b.number
          )

        {:ok, Map.merge(context, %{old_response: old_response, new_response: new_response})}
      end

      then_ "copy A enters the queue and only copy B is refused over that issue", context do
        refute context.old_response.isError, response_text(context.old_response)
        assert response_text(context.old_response) =~ "Queued for promotion"
        assert context.new_response.isError
        assert response_text(context.new_response) =~ context.issue_id
        {:ok, context}
      end
    end
  end
end
