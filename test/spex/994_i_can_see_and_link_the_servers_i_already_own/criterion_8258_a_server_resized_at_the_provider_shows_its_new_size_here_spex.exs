defmodule CodeMySpecSpex.Story994.Criterion8258Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8258 — A server resized at the provider shows its new size here.

  The screen reports the provider, not our memory of it. Sam resizes a box in
  the Hetzner console — which is a perfectly ordinary thing to do — and this
  page has no business telling him it is still the old size.

  Same doctrine as `Hetzner.find_server/2`, whose own docs say it is how a
  step's state is checked against the provider rather than read back from our
  row. A stale size here would be the first crack in that.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A server resized at the provider shows its new size here" do
    scenario "the size shown is the one the provider reports now" do
      given_ "a linked server CodeMySpec recorded at one size", context do
        context = stage_servers(context, [provider_server(%{name: "worker", size: "cpx11"})])

        {:ok, _view, html} = live(context.conn, "/app/servers")

        assert html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server'][data-name='worker']")
               |> Floki.attribute("data-size") == ["cpx11"],
               "expected the original size to be showing before the resize"

        {:ok, context}
      end

      when_ "he resizes it in the provider's console and reopens the screen", context do
        # The provider now reports something different. Nothing told
        # CodeMySpec; that is the point.
        context = stage_servers(context, [provider_server(%{name: "worker", size: "cpx31"})])

        {:ok, _view, html} = live(context.conn, "/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it shows the size the provider reports", context do
        assert context.html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server'][data-name='worker']")
               |> Floki.attribute("data-size") == ["cpx31"],
               "the screen showed a remembered size rather than the provider's"

        {:ok, context}
      end

      then_ "and the earlier record is not what decided the answer", context do
        # Scoped to the row, not the page. The size catalogue in the
        # provisioning form legitimately lists cpx11 as something Sam could
        # buy — a page-wide grep would fail on the form rather than on a
        # stale record, which is the opposite of what this asks.
        sizes =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server']")
          |> Floki.attribute("data-size")

        refute "cpx11" in sizes,
               "a server is still displaying the superseded size, so something is " <>
                 "reading our record rather than the provider"

        {:ok, context}
      end
    end
  end
end
