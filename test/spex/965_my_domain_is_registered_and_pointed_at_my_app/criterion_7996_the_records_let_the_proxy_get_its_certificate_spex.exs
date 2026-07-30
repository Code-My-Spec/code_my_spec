defmodule CodeMySpecSpex.Story965.Criterion7996Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7996 — The records let the proxy get its certificate.

  The DNS records setup writes must leave certificate issuance able to
  succeed: the challenge has to reach the server. In practice that means
  the records are unproxied — a proxied record terminates the HTTP-01
  challenge at Cloudflare's edge and the proxy on Sam's box never sees it,
  so issuance hangs with correct-looking DNS.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @dns_cassette "cloudflare_dns_records_created_per_environment"
  @cert_cassette "kamal_proxy_certificate_issued"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The records let the proxy get its certificate" do
    scenario "the challenge reaches the server and the certificate is issued" do
      given_ "the DNS step has created the records for an environment", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        html =
          ReqCassette.with_cassette(@dns_cassette, [mode: :replay], fn ->
            view
            |> element("[data-test='setup-step'][data-step='dns'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, context |> Map.put(:view, view) |> Map.put(:dns_html, html)}
      end

      then_ "the records are unproxied so the challenge can reach the server", context do
        records =
          context.dns_html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='dns-record']")

        assert records != [], "expected DNS records to have been created"

        for record <- records do
          name = record |> Floki.attribute("data-name") |> List.first()
          proxied = record |> Floki.attribute("data-proxied") |> List.first()

          assert proxied == "false",
                 "expected #{name} to be unproxied so HTTP-01 reaches the origin, got proxied=#{inspect(proxied)}"
        end

        {:ok, context}
      end

      when_ "the proxy requests a certificate for that hostname", context do
        html =
          ReqCassette.with_cassette(@cert_cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='tls'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the certificate is issued", context do
        assert context.html =~ ~r/data-step="tls"[^>]*data-state="done"/,
               "expected certificate issuance to succeed against the records setup wrote"

        {:ok, context}
      end
    end
  end
end
