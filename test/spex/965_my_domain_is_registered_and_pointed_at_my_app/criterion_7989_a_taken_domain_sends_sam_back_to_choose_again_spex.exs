defmodule CodeMySpecSpex.Story965.Criterion7989Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7989 — A taken domain sends Sam back to choose again.

  When the domain is already registered by someone else, setup says so
  and asks for another — and attempts no charge. A registration attempt
  against a taken domain is money at risk for nothing.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_domain_check_unavailable"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A taken domain sends Sam back to choose again" do
    scenario "an unavailable domain is reported and no charge is attempted" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he checks a domain someone else already owns", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "google.com"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup says it is taken and asks for another", context do
        assert has_element?(
                 context.view,
                 "[data-test='domain-availability'][data-available='false']"
               ),
               "expected the domain to be reported unavailable"

        # Anchor: he can still try again — this is a redirect back to the
        # choice, not a dead end.
        assert has_element?(context.view, "[data-test='domain-form']"),
               "expected the domain form to remain so Sam can choose again"

        {:ok, context}
      end

      then_ "no charge is attempted", context do
        refute has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected no purchase confirmation to be offered for a taken domain"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected the domain step not to complete on an unavailable name"

        {:ok, context}
      end
    end
  end
end
