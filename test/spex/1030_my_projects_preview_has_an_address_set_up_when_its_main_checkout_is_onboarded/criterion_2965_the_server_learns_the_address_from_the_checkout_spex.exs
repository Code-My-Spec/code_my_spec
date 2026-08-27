defmodule CodeMySpecSpex.Story1030.Criterion2965Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2965 — The server learns the address from the checkout.

  Rule: The harness reports the recorded address on join, so the server's copy
  comes from the checkout rather than being set independently.

  The web app has no disk. It cannot read `.cms_harness.json` to find out where
  to point a frame, so the server keeps a copy — and the only safe way to hold
  the same fact twice is for one of them to be downstream of the other. The file
  is the source, the join is the report. Exactly how `root` already works.

  Set independently, the two drift, and the drift is silent: the panel frames an
  address the checkout stopped using and shows the founder somebody else's app,
  or a blank frame, with both sides believing they are correct.

  ## Observed through the panel, not the database

  A `then_` may not read the DB, and here that restriction is doing real work
  rather than being obeyed. The claim is not "a column got written" — it is that
  the founder sees their app. A spec that checked the row would pass over a
  panel that never reads it, which is exactly the state this whole story was
  found in.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  @url "https://preview-2965.example.test"

  spex "What the server holds comes from the checkout" do
    scenario "The server learns the address from the checkout" do
      given_ "a project whose panel has no preview to show", context do
        {:ok, live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}")

        refute html =~ @url,
               "the address was already there before the checkout reported it, so " <>
                 "this scenario cannot show that the join is what carried it"

        {:ok, Map.put(context, :live, live)}
      end

      when_ "its main checkout joins, reporting where its preview answers", context do
        reply = join_working_copy(context, "/workspace/main", "main", preview_url: @url)

        {:ok, Map.put(context, :working_copy_id, reply.working_copy_id)}
      end

      then_ "the project's preview is the address the checkout named", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}")

        assert html =~ @url,
               "the server did not take the address from the join, so the panel has " <>
                 "nothing to frame for a project whose checkout knows perfectly well " <>
                 "where its preview is. Nobody would ever be told why."

        {:ok, context}
      end
    end
  end
end
