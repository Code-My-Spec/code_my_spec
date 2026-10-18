defmodule CodeMySpecSpex.Story1116.Criterion2196Spex do
  @moduledoc "A cross-story blocking issue keeps this story out of QA until it is fixed."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryIssueBagHelpers, as: Bag

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An accepted issue owned by another story that blocks this story's QA keeps this story out of QA until that issue's fix lands, and QA is not offered again while nothing has changed since the last partial attempt",
    criterion: 2196 do
    scenario "A blocker re-triaged to another story still holds this story's QA" do
      given_ "a partial QA attempt cited an issue later re-triaged to a different story",
             context do
        context =
          context
          |> Bag.team()
          |> Bag.issue(:blocker)
          |> Bag.submit(:blocker)
          |> Bag.ready()
          |> Bag.review()

        context = Bag.qa_result(context, "partial", [:blocker])
        other = Fixtures.authored_story(context.scope, "Unrelated story owning the blocker")

        {:ok, _} =
          CodeMySpec.Issues.update_issue(context.scope, context.blocker, %{story_id: other.id})

        {:ok, Map.put(context, :other_story, other)}
      end

      when_ "the team asks for QA work twice with nothing changed", context do
        {:ok,
         Map.merge(context, %{
           first_ask: Bag.next(context, :qa),
           second_ask: Bag.next(context, :qa)
         })}
      end

      then_ "QA stays withheld and asking again does not open a new review", context do
        refute context.first_ask =~ "requirement_name=`qa_complete`"
        assert context.first_ask == context.second_ask
        assert Bag.issue_text(context, :blocker) =~ "**Status:** accepted"
        {:ok, context}
      end

      when_ "the blocking issue's fix lands", context do
        # `Issues.resolve_issue/3` itself refuses a story-owned issue with no
        # working-copy assignment ("must go through shared story QA and
        # promotion") — correct for the real surface, but re-walking the
        # other story's own promotion pipeline is criterion 2101's scenario,
        # not this one. Same direct-write style used elsewhere in this suite
        # (`StoryIssueBag.certify`) to set background state a fixture owns.
        context.blocker
        |> Ecto.Changeset.change(status: :resolved, resolution: "Fixed on the owning story.")
        |> CodeMySpec.Repo.update!()

        # A direct write bypasses `Issues.resolve_issue/3`'s own announce
        # (story 1116, criterion 2196: the graph recomputes from events, not
        # from reading the table on request — see `QaFixtures`).
        CodeMySpec.Requirements.GraphInputs.announce(context.scope, "Issues", [], :project_wide)

        {:ok, context}
      end

      then_ "the team's QA work becomes available again", context do
        assert Bag.next(context, :qa) =~ "requirement_name=`qa_complete`"
        {:ok, context}
      end
    end
  end
end
