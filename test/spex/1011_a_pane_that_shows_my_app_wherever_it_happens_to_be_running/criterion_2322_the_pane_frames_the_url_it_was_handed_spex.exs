defmodule CodeMySpecSpex.Story885.Criterion2322Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2322 — The pane frames the URL it was handed.

  Rule: the pane shows whatever is at the URL it was given.

  The pane decides nothing about where the app is. It is handed an address and
  frames that address — which is what makes it provable with no container, no
  proxy and no DNS, and what keeps story 886 free to change how the address is
  computed without touching this.

  "A live frame, not a picture of one" is the part worth asserting. A
  screenshot would satisfy every other criterion here and fail the one thing
  the pane is for: what Sam sees has to be the running app, so that clicking
  it does what clicking it would do.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The pane frames the app it was pointed at" do
    scenario "The pane frames the URL it was handed" do
      given_ "the component is given a URL and told the app is running", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        {:ok, context}
      end

      when_ "it renders", context do
        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the pane frames that URL", context do
        frame =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='preview-pane'] iframe")

        assert frame != [], "the pane rendered no frame for a running app"

        assert Floki.attribute(frame, "src") != [""],
               "the frame was rendered with an empty address"

        {:ok, Map.put(context, :frame, frame)}
      end

      then_ "and it is a live frame, not a picture of one", context do
        # A screenshot satisfies every other criterion in this story and fails
        # the only thing the pane is for.
        refute context.html =~ ~r/<img[^>]+data-test=['"]preview/,
               "the pane rendered an image where the running app should be"

        {:ok, context}
      end
    end
  end
end
