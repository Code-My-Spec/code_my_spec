defmodule CodeMySpecSpex.Story885.Criterion2323Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2323 — A running state with no URL is refused, not framed.

  Rule: the pane shows whatever is at the URL it was given.

  The contradictory input, and the pane refuses it rather than doing its best
  with it. An iframe pointed at an empty address renders a blank rectangle
  indistinguishable from an app that rendered nothing — so the failure would
  land on Sam as "my app is broken" when the truth is that we do not know
  where it is.

  Not a contrived state: `Workspace.url/1` answers nil for a running workspace
  whose port is not set, which is what a boot that recorded success without a
  published port leaves behind.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pane refuses to frame an address it does not have" do
    scenario "A running state with no URL is refused, not framed" do
      given_ "the component is told the app is running but given no URL", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running_without_url)

        {:ok, context}
      end

      when_ "it renders", context do
        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "it does not frame an empty address", context do
        frames = context.html |> Floki.parse_document!() |> Floki.find("iframe")

        assert Enum.all?(frames, fn frame ->
                 src = frame |> then(&[&1]) |> Floki.attribute("src") |> List.first()
                 is_binary(src) and src != ""
               end),
               "an iframe was rendered with no address, which shows Sam a blank box " <>
                 "and reads as his app being broken"

        {:ok, context}
      end

      then_ "and it says the preview is unavailable rather than showing a blank pane",
            context do
        assert context.html =~ ~r/unavailable/i,
               "expected the pane to say the preview is unavailable, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
