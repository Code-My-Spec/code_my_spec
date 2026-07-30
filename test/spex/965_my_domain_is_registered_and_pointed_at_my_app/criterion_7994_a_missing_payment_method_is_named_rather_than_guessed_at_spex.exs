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

  @cassette "cloudflare_registrar_no_payment_method"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A missing payment method is named rather than guessed at" do
    scenario "the missing prerequisite is named and no partial registration remains" do
      given_ "Sam has no payment method configured at Cloudflare", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step tries to register", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> form("[data-test='domain-form']", domain: %{name: "sams-new-thing.com"})
            |> render_submit()

            context.view |> element("[data-test='confirm-purchase']") |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup names exactly which prerequisite is missing", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='needs-sam'][data-step='domain']")
          |> Floki.text()

        assert text =~ ~r/payment method/i,
               "expected the payment method to be named specifically, got: #{inspect(text)}"

        {:ok, context}
      end

      then_ "no half-registered domain is left behind", context do
        registrations =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='domain']")

        assert registrations == [],
               "expected no domain resource recorded when registration could not proceed"

        assert context.html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected the domain step to come to rest as errored rather than partially done"

        {:ok, context}
      end
    end
  end
end
