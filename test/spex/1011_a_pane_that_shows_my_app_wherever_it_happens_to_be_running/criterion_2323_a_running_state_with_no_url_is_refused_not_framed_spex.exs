defmodule CodeMySpecSpex.Story885.Criterion2323Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2323 — A running state with no URL is refused, not framed.

  Rule: the pane shows whatever is at the URL it was given.

  The contradictory input, and the pane refuses it rather than doing its best
  with it. An iframe pointed at an empty address renders a blank rectangle
  indistinguishable from an app that rendered nothing — so the failure lands on
  Sam as "my app is broken" when the truth is that we do not know where it is.

  ## Why this is handed values rather than driven through a page

  The criterion says "the component is given a URL", and 885 says how to prove
  it: "hand it values, assert what renders". That is not a shortcut around the
  page — the page cannot produce this input. `Workspace.booting_changeset/2`
  requires a port, so a workspace row that is running without an address does
  not exist and cannot be made.

  Which is the point of the pane being a pure function of its input. It will be
  handed values by more than one host over its life, and the contract has to
  hold for all of them rather than only for the states today's host happens to
  compute.

  Surface: the component's contract.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CodeMySpecWeb.PreviewComponents

  spex "A pane refuses to frame an address it does not have" do
    scenario "A running state with no URL is refused, not framed" do
      given_ "the component is told the app is running but given no URL", context do
        # given: already true — these two values *are* the precondition. The
        # component's whole input is `src` and `state`, so naming them here is
        # establishing it; there is no app to drive into this shape, because
        # `booting_changeset/2` requires a port and no workspace row can be
        # running without an address.
        {:ok, Map.merge(context, %{state: :running, src: nil})}
      end

      when_ "it renders", context do
        html =
          render_component(&PreviewComponents.pane/1, state: context.state, src: context.src)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it does not frame an empty address", context do
        refute context.html =~ "<iframe",
               "an iframe was rendered with no address, which shows Sam a blank box " <>
                 "and reads as his app being broken: #{context.html}"

        {:ok, context}
      end

      then_ "and it says the preview is unavailable rather than showing a blank pane",
            context do
        # The state's own marker rather than the word "unavailable", which the
        # pane could print in any number of places. This renders the component
        # directly, so there is no view to ask — the attribute is the anchor.
        assert context.html =~ ~s(data-test="preview-unavailable"),
               "expected the pane to say the preview is unavailable, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
