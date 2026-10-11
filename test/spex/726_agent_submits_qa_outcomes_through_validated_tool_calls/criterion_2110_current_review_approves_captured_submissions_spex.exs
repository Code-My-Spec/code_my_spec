defmodule CodeMySpecSpex.Story726.Criterion2110Spex do
  @moduledoc "A current review approves its captured submissions."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A current review approves its captured submissions", criterion: 2110 do
    scenario "A current review approves its captured submissions" do
      given_ "a story team with captured QA work", context do
        context =
          context
          |> Bag.team()
          |> Bag.issue(:a)
          |> Bag.issue(:b)
          |> Bag.submit(:a)
          |> Bag.submit(:b)
          |> Bag.ready()
          |> Bag.review()

        {:ok, context}
      end

      when_ "QA passes its unchanged review", context do
        context = Bag.qa_result(context, "pass")
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        assert Bag.qa_requirements(context) =~ context.story.title
        history = Bag.history(context)
        assert history =~ Bag.revision()
        assert history =~ context.a.id
        assert history =~ context.b.id

        {:ok, view, _} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/stories/#{context.story.number}"
          )

        reviewed = view |> element("[data-role='qa-reviewed-work']") |> render()
        assert reviewed =~ Bag.revision()
        assert reviewed =~ context.a.id
        assert reviewed =~ context.b.id
        assert reviewed =~ "Review started"
        {:ok, context}
      end
    end
  end
end
