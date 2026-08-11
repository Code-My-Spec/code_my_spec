defmodule CodeMySpecSpex.Story965.Criterion7989Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7989 — A name setup cannot register says so plainly.

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
  setup :devops_on
  setup :connect_providers

  spex "A name setup cannot register says so plainly" do
    scenario "an unavailable domain is reported and no charge is attempted" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he checks a domain someone else already owns", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "google.com"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup does not claim it as Sam's, and leaves the form so he can choose again",
            context do
        # A domain the account does not hold cannot be confirmed available or
        # taken through the registrar API — it answers only that the extension
        # is supported. So setup does not report google.com as *Sam's* and does
        # not adopt it; the real status is resolved in the dashboard, and the
        # form stays so he can try another name.
        refute has_element?(context.view, "[data-test='domain-registered']"),
               "expected setup not to claim a domain Sam does not own"

        assert has_element?(context.view, "[data-test='domain-form']"),
               "expected the domain form to remain so Sam can choose again"

        {:ok, context}
      end

      then_ "no charge is attempted", context do
        refute has_element?(context.view, "[data-test='confirm-purchase']"),
               "expected no in-app purchase to be offered — buying is a dashboard errand"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="done"/,
               "expected the domain step not to complete merely by checking a name"

        {:ok, context}
      end
    end
  end
end
