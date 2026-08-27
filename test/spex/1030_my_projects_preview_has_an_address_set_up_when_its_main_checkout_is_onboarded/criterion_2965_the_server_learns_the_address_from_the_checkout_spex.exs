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

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  # The panel lives in `CodeMySpecWeb`, not the local app the case template
  # points at by default. Without this the route 404s and `live/2` fails
  # inside LiveViewTest rather than saying which router it looked in.
  # Story 1025's criteria drive the same page and override it the same way.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.MainAgentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The agent runs in another process, so it needs the connection this one
    # holds.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # Without a provider the main agent is refused, no conversation is ever
  # created, and the preview panel has no page to sit beside. The refusal is
  # deliberate — an agent started on a credential that does not resolve fails on
  # its first model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  @url "https://preview-2965.example.test"

  spex "What the server holds comes from the checkout" do
    scenario "The server learns the address from the checkout" do
      given_ "its main checkout on the harness, reporting where its preview answers",
             context do
        context = given_a_main_checkout(context, "spex_2965", preview_url: @url)

        # The conversation has to exist for there to be a screen with a preview
        # beside it, and saying something is how one comes into being — the panel
        # is part of the page a person talks to their agent on, not a page of its
        # own.
        {:ok, Map.put(context, :path, say_to_main_agent(context, "how is it going"))}
      end

      # Opening it is the action, because every panel starts shut. Asserting on
      # the page without opening one would be asserting on a closed drawer — the
      # address is not in the document until the pane is rendered, so a spec that
      # skipped this would fail for a reason that has nothing to do with the
      # criterion.
      when_ "the founder opens the preview beside the conversation", context do
        {:ok, live, _html} = live(context.conn, context.path)

        html = live |> element("[data-test='panel-tab-preview']") |> render_click()

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "it frames the address the checkout named", context do
        assert context.html =~ @url,
               "the server did not take the address from the join, so the panel has " <>
                 "nothing to frame for a project whose checkout knows perfectly well " <>
                 "where its preview is. Nobody would ever be told why."

        {:ok, context}
      end
    end
  end
end
