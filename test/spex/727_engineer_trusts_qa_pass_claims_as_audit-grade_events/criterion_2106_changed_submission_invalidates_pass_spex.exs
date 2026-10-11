defmodule CodeMySpecSpex.Story727.Criterion2106Spex do
  @moduledoc "Submitting new fixes invalidates the prior pass."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Submitting new fixes invalidates the prior pass", criterion: 2106 do
    scenario "Submitting new fixes invalidates the prior pass" do
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

        context = Bag.qa_result(context, "pass")
        {:ok, context}
      end

      when_ "coding submits a changed fix", context do
        context = Bag.submit(context, :a, evidence: Bag.evidence() <> " Changed fix.")
        {:ok, context}
      end

      then_ "QA qualifies only for the reviewed story work", context do
        refute Bag.qa_requirements(context) =~ context.story.title
        history = Bag.history(context)
        assert history =~ "pass"
        assert history =~ "invalidated"
        assert history =~ context.a.id
        {:ok, context}
      end
    end
  end
end
