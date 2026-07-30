defmodule CodeMySpecSpex.Story965.Criterion7988Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7988 — Sam picks a name and sees what it costs.

  Before any money moves, Sam types the domain he wants and gets back
  whether it is available and what it costs. Registrations are
  non-refundable, so price has to be on screen *before* the decision, not
  after it.

  The Cloudflare availability/pricing round-trip is replayed from a
  ReqCassette — the spec drives the page and the app's own Req client is
  what gets intercepted.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_domain_check_available_with_price"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam picks a name and sees what it costs" do
    scenario "an available domain comes back with its price before he commits" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he types the domain he wants and setup checks it", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "he sees whether it is available", context do
        assert has_element?(
                 context.view,
                 "[data-test='domain-availability'][data-available='true']"
               ),
               "expected the availability answer to be shown for the domain Sam named"

        {:ok, context}
      end

      then_ "he sees what it costs before deciding", context do
        price =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='domain-price']")
          |> Floki.text()

        assert price =~ ~r/\d/,
               "expected a price to be shown before the purchase decision, got: #{inspect(price)}"

        refute has_element?(context.view, "[data-test='domain-step'][data-state='registered']"),
               "expected nothing to be bought merely by checking availability"

        {:ok, context}
      end
    end
  end
end
