defmodule CodeMySpecSpex.Story885.Criterion2321Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2321 — Sam checks the app on a phone-sized screen.

  Rule: Sam can see the app at a different viewport size.

  "It is the app deciding how to look, not the pane scaling a picture" is the
  whole criterion. Narrowing the frame makes the target's own media queries
  fire, so what Sam sees is the mobile layout that was built. A CSS transform
  on a desktop render would look approximately right and be a lie — it would
  show a shrunken desktop page and hide exactly the breakpoint bug he opened
  the narrow view to find.

  The width is an assign the host owns. The pane stays a pure function of its
  input, which is what keeps it provable by handing it values.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam can look at his app the way a phone would" do
    scenario "Sam checks the app on a phone-sized screen" do
      given_ "Sam's app is showing in the pane", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        {:ok, view, _html} = live(context.conn, "/build/preview")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he chooses a narrow viewport", context do
        html =
          context.view
          |> element("[data-test='viewport-phone']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the app re-renders at that width", context do
        pane =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='preview-pane']")

        assert Floki.attribute(pane, "data-viewport") == ["phone"],
               "the pane did not narrow, so the app never saw a phone-sized viewport"

        {:ok, Map.put(context, :pane, pane)}
      end

      then_ "and it is the app deciding how to look, not the pane scaling a picture",
            context do
        # A transform would shrink a desktop render and hide the breakpoint bug
        # he opened the narrow view to find.
        refute Floki.raw_html(context.pane) =~ ~r/transform:\s*scale/,
               "the pane scaled the rendered app instead of narrowing the frame it " <>
                 "renders into"

        {:ok, context}
      end
    end
  end
end
