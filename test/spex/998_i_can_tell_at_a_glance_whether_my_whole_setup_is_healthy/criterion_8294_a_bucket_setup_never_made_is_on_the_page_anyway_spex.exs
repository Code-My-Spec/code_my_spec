defmodule CodeMySpecSpex.Story998.Criterion8294Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8294 — A bucket setup never made is on the page anyway.

  This is why the page enumerates providers rather than verifying our own
  records one by one. A check that starts from what setup wrote down can only
  ever confirm or deny those things; a resource nobody recorded is invisible to
  it, and invisible is exactly the state that costs money quietly.

  `mix cms.provisioning_leaks` exists because this happens — a crashed teardown
  leaves resources behind, and the next run finds them already there and
  reports success on residue.

  Marked as ours-or-not, because the distinction changes what he does about it.
  It must not be the same as "safe to ignore": a bucket we did not create is
  still on the bill.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A bucket setup never made is on the page anyway" do
    scenario "a resource with no record of ours is still listed" do
      given_ "a bucket in Sam's provider account that setup has no record of", context do
        context =
          stage_inventory(context, %{
            hetzner: [
              inventory_resource(%{kind: "bucket", location: "made-by-hand-years-ago"})
            ]
          })

        {:ok, context}
      end

      when_ "he opens the resources page", context do
        {:ok, view, _html} = live(context.conn, ~p"/app/resources")

        {:ok, context |> Map.put(:document, Floki.parse_document!(render_async(view)))}
      end

      then_ "the bucket is listed", context do
        bucket =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='made-by-hand-years-ago']"
          )

        assert bucket != [],
               "a resource we have no record of is absent from the page, so the only " <>
                 "things that can ever be found are the ones already written down"

        {:ok, Map.put(context, :bucket, bucket)}
      end

      then_ "and it is marked as one CodeMySpec did not create", context do
        assert Floki.attribute(context.bucket, "data-origin") == ["unrecorded"],
               "he cannot tell what he is looking at, and whether it is ours changes " <>
                 "whether removing it is his call or a bug in our teardown"

        {:ok, context}
      end

      then_ "and nothing implies it can be ignored because we have no record of it",
            context do
        refute Floki.text(context.bucket) =~ ~r/ignore|not ours|unrelated|safe/i,
               "the page suggested a resource is somebody else's problem; it is on the " <>
                 "same bill as the ones we made"

        {:ok, context}
      end
    end
  end
end
