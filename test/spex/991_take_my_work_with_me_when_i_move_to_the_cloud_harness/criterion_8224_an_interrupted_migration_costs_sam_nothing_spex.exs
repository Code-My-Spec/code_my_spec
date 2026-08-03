defmodule CodeMySpecSpex.Story991.Criterion8224Spex do
  @moduledoc """
  Story 991 — Criterion 8224 — An interrupted migration costs Sam nothing.

  Covers Rule "A migration that does not finish leaves the local harness
  working."

  8231 asks what a failure leaves on the cloud: nothing. This asks the question
  from Sam's side of the wire, which is the one he cares about — his own
  machine still has everything, and he can run it again without tidying up
  first.

  Those are different properties. A migration could roll the cloud back
  perfectly and still have damaged the local project on its way out, by marking
  records as sent or locking them while it worked. The reason this holds is
  that the export only reads.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A failed migration leaves the local harness whole" do
    scenario "An interrupted migration costs Sam nothing" do
      given_ "Sam has a project on the local harness", context do
        local = Fixtures.paid(context.scope)
        story = Fixtures.authored_story(local, "Everything he has")
        cloud = Fixtures.other_project_scope(local, "Cloud target")

        {:ok,
         context |> Map.put(:local, local) |> Map.put(:cloud, cloud) |> Map.put(:story, story)}
      end

      when_ "the migration fails part-way", context do
        broken =
          context.local
          |> Fixtures.exported()
          |> Map.put("criteria", [
            %{"local_id" => "orphan", "story_local_id" => 999_999, "description" => "unplaceable"}
          ])

        assert Fixtures.migrate(context.cloud, broken).status == 422

        {:ok, context}
      end

      then_ "his local harness still holds everything it did before", context do
        local_story = Fixtures.local_story(context.local, context.story.id)

        assert local_story, "a failed migration must not cost him the work it was copying"
        assert local_story.title == "Everything he has"

        {:ok, context}
      end

      and_ "he can run it again without cleaning anything up first", context do
        assert Fixtures.migrate(context.cloud, Fixtures.exported(context.local)).status == 200,
               "the retry has to work on the state the failure left, not on a tidied one"

        titles = context.cloud |> Fixtures.cloud_stories() |> Enum.map(& &1.title)
        assert "Everything he has" in titles

        {:ok, context}
      end
    end
  end
end
