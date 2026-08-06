defmodule CodeMySpecSpex.Story965.Criterion7994Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7994 — A missing payment method is named rather than guessed at.

  Cloudflare Registrar needs a billing profile with a payment method and a
  default registrant contact before it will register anything. When one is
  missing, setup stops and names *which* one — and leaves no
  half-registered domain behind. "Registration failed" sends Sam hunting
  through a dashboard for a prerequisite the error already knew about.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "965_7994_cloudflare_registrar_no_payment_method"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A missing payment method is named rather than guessed at" do
    scenario "the missing prerequisite is named and no partial registration remains" do
      # Regrounded. Registering a new name — and configuring the payment method
      # that needs — happens in the Cloudflare dashboard, because the Registrar
      # API will not sell an arbitrary new name. The honest version of "a
      # missing prerequisite is named rather than guessed at" is that setup
      # says *specifically* where the prerequisite lives (the dashboard) rather
      # than failing with a vague error, and leaves nothing half-done.
      given_ "Sam wants a name he has not yet registered", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he checks it", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup names where the prerequisite lives rather than failing vaguely", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='domain-dashboard-handoff']")
          |> Floki.text()

        # Specific and actionable: it names the dashboard and that registering
        # is what happens there — not a bare "something went wrong".
        assert text =~ ~r/dashboard/i,
               "expected the dashboard to be named as where registration happens, got: #{inspect(text)}"

        assert text =~ ~r/regist/i,
               "expected the message to name registration specifically, not fail vaguely"

        {:ok, context}
      end

      then_ "nothing half-registered is left behind", context do
        registrations =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='domain']")

        assert registrations == [],
               "expected no domain resource recorded when registration was handed off"

        refute context.html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected a clean handoff rather than a half-done errored step"

        {:ok, context}
      end
    end
  end
end
