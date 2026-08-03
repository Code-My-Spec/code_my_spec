defmodule CodeMySpecSpex.Story991.Criterion8229Spex do
  @moduledoc """
  Story 991 — Criterion 8229 — Work done locally after migrating does not
  appear on the cloud.

  Covers Rule "Migration is a copy, not a link — the two projects do not stay
  in step afterwards."

  The consequence of keeping the local copy, and the one most likely to
  surprise. Both harnesses hold the project and nothing stops Sam opening
  either, so the honest behaviour is that they diverge from the moment he
  migrates and he picks one.

  Two projects here, not one. A first draft used a single project as both ends
  and could not fail: reading and writing the same records, "the cloud" and
  "the local harness" are the same rows, and divergence has nowhere to happen.
  That is the same collapse story 984's spex suffered — a spec whose two sides
  are one process proves the thing it was written to catch cannot be seen.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The two projects do not stay in step" do
    scenario "Work done locally after migrating does not appear on the cloud" do
      given_ "Sam has migrated his local project to a cloud one", context do
        local = Fixtures.paid(context.scope)
        Fixtures.authored_story(local, "Written before migrating")

        cloud = Fixtures.other_project_scope(local, "Sam's cloud project")
        assert Fixtures.migrate(cloud, Fixtures.exported(local)).status == 200

        {:ok, context |> Map.put(:local, local) |> Map.put(:cloud, cloud)}
      end

      when_ "he writes another story on the local harness", context do
        Fixtures.authored_story(context.local, "Written after migrating")

        {:ok, context}
      end

      then_ "the new story is not on the cloud", context do
        titles = context.cloud |> Fixtures.cloud_stories() |> Enum.map(& &1.title)

        assert "Written before migrating" in titles,
               "what he migrated has to be there, or the scenario is testing nothing"

        refute "Written after migrating" in titles,
               "a copy that kept updating itself would be a sync, which this is not"

        {:ok, context}
      end

      and_ "migrating again is how later work crosses", context do
        assert Fixtures.migrate(context.cloud, Fixtures.exported(context.local)).status == 200

        titles = context.cloud |> Fixtures.cloud_stories() |> Enum.map(& &1.title)

        assert "Written after migrating" in titles

        assert Enum.count(titles, &(&1 == "Written before migrating")) == 1,
               "the second crossing must not duplicate what the first already carried"

        {:ok, context}
      end
    end
  end
end
