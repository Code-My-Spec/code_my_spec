defmodule CodeMySpecSpex.Story998.Criterion8295Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8295 — One provider being down does not empty the page.

  Four providers, four independent answers. Letting one failure decide the
  whole page would mean a Cloudflare outage reporting that Sam owns no servers
  — the same "failure to ask, rendered as an answer" this epic has now found in
  five places (8259, 8285, and the credential defect on 994 among them).

  The distinction the page has to keep is between *we asked and there is
  nothing* and *we could not ask*. Only the first is safe to draw a conclusion
  from, and the health count must not treat an unreadable provider as clean.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "One provider being down does not empty the page" do
    scenario "the providers that answered are listed; the one that did not says so" do
      given_ "resources at three providers, one of which cannot be reached", context do
        context =
          stage_inventory(context, %{
            hetzner: [inventory_resource(%{kind: "server", location: "hetzner/uat-box"})],
            resend: [
              inventory_resource(%{kind: "sending_domain", location: "resend/example.com"})
            ],
            cloudflare: {:error, :unauthorized}
          })

        {:ok, context}
      end

      when_ "he opens the resources page", context do
        {:ok, view, _html} = live(context.conn, "/app/resources")

        {:ok, context |> Map.put(:document, Floki.parse_document!(render_async(view)))}
      end

      then_ "the providers that answered are listed as normal", context do
        locations =
          context.document
          |> Floki.find("[data-test='resource']")
          |> Floki.attribute("data-location")

        assert "hetzner/uat-box" in locations,
               "one provider failing took the others down with it"

        assert "resend/example.com" in locations

        {:ok, context}
      end

      then_ "the one that could not be asked says so, and why", context do
        error = Floki.find(context.document, "[data-test='provider-error'][data-provider='cloudflare']")

        assert error != [],
               "a provider that could not be asked produced no error, so its absence " <>
                 "reads as having nothing"

        assert Floki.text(error) =~ ~r/unauthor|refus|reach|ask/i,
               "the error must say what went wrong, not merely that something did"

        {:ok, context}
      end

      then_ "and the health count does not treat an unreadable provider as clean", context do
        summary = Floki.find(context.document, "[data-test='health-summary']")

        refute Floki.attribute(summary, "data-status") == ["healthy"],
               "the account was declared healthy while a whole provider went unread — " <>
                 "which is a guess dressed as an all-clear"

        {:ok, context}
      end
    end
  end
end
