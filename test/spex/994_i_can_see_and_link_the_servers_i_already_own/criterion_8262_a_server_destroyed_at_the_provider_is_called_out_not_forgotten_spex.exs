defmodule CodeMySpecSpex.Story994.Criterion8262Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8262 — A server destroyed at the provider is called out, not forgotten.

  A linked server that stops existing must not simply drop off the list,
  because things still point at it. QA found the shape of this on a real run:
  a destroyed box left `qa2.astralbi.com` resolving to a released Hetzner IP,
  which is a subdomain of the customer's own domain answering from a machine
  they no longer own. Hetzner reassigns those addresses.

  Silently removing the row would make that state invisible at exactly the
  moment someone needs to see it. The screen's job is to say the box is gone,
  not to agree that it never mattered.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A server destroyed at the provider is called out, not forgotten" do
    scenario "a linked server that no longer exists is shown as missing" do
      given_ "Sam linked a server", context do
        context = stage_servers(context, [provider_server(%{name: "doomed-box"})])

        {:ok, view, _html} = live(context.conn, "/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='doomed-box']")
        |> render_click()

        {:ok, context}
      end

      when_ "he destroys it in the provider's console and reopens the screen", context do
        # The provider no longer reports it at all.
        context = stage_servers(context, [])

        {:ok, _view, html} = live(context.conn, "/app/servers")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the server is shown as missing at the provider", context do
        row =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-name='doomed-box']")

        assert row != [],
               "the destroyed server vanished from the list — anything still pointed at it " <>
                 "is now pointed at nothing, and the screen is the only place that could say so"

        assert Floki.attribute(row, "data-missing") == ["true"],
               "the server is listed but not marked as missing at the provider"

        {:ok, context}
      end
    end
  end
end
