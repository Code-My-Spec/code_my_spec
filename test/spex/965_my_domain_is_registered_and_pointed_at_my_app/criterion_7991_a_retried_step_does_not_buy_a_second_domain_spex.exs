defmodule CodeMySpecSpex.Story965.Criterion7991Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7991 — A retried step does not buy a second domain.

  Idempotence with money attached. Once Sam owns the domain, re-running
  the domain step recognises that and charges nothing — no second
  registration, no second invoice. Every other step converging is a
  tidiness property; this one is the difference between a re-run and a
  bill.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @register_cassette "cloudflare_domain_register_ok"
  @already_owned_cassette "cloudflare_domain_already_owned"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A retried step does not buy a second domain" do
    scenario "re-running the domain step recognises the domain is already owned" do
      given_ "Sam confirmed and the domain was registered", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@register_cassette, [mode: :replay], fn ->
          view
          |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
          |> render_submit()

          view |> element("[data-test='confirm-purchase']") |> render_click()
        end)

        assert render(view) =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected the first registration to complete"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step runs again", context do
        ReqCassette.with_cassette(@already_owned_cassette, [mode: :replay], fn ->
          context.view
          |> element("[data-test='setup-step'][data-step='domain'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup recognises he already owns it", context do
        assert context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected the repeated run to settle as done"

        assert has_element?(
                 context.view,
                 "[data-test='domain-registered'][data-owned-already='true']"
               ),
               "expected setup to record that the domain was already owned rather than newly bought"

        {:ok, context}
      end

      then_ "it does not register or charge a second time", context do
        registrations =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='domain']")

        assert length(registrations) == 1,
               "expected exactly one domain registration after two runs, got #{length(registrations)}"

        refute has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected no second purchase confirmation to be offered"

        {:ok, context}
      end
    end
  end
end
