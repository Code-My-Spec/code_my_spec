defmodule CodeMySpecSpex.Story966.Criterion8006Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8006 — Sam's app answers on his domain over a valid certificate.

  The payoff criterion: requesting the environment's hostname over HTTPS
  returns Sam's app, over a certificate a browser trusts, with no warning.
  Everything else in this story exists to make this true.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "environment_https_probe_ok"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's app answers on his domain over a valid certificate" do
    scenario "the environment answers over HTTPS with a trusted certificate" do
      given_ "an environment has deployed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup verifies the environment over HTTPS", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='verify'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "his app comes back on his own hostname", context do
        verification =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='environment-verification']")

        # Anchor: a verification was recorded.
        assert verification != [], "expected setup to record the HTTPS verification"

        scheme = verification |> Floki.attribute("data-scheme") |> List.first()
        status = verification |> Floki.attribute("data-status") |> List.first()
        host = verification |> Floki.attribute("data-host") |> List.first()

        assert scheme == "https",
               "expected the check to be made over HTTPS, got #{inspect(scheme)}"

        assert status == "200",
               "expected the app to answer 200 on its own hostname, got #{inspect(status)}"

        assert is_binary(host) and host != "",
               "expected the verification to name the hostname it requested"

        {:ok, Map.put(context, :verification, verification)}
      end

      then_ "the certificate is one a browser trusts, with no warning", context do
        cert_valid = context.verification |> Floki.attribute("data-cert-valid") |> List.first()

        assert cert_valid == "true",
               "expected a trusted certificate rather than a self-signed or expired one"

        refute context.html =~ ~r/data-cert-warning="true"/,
               "expected no certificate warning on the verified environment"

        {:ok, context}
      end
    end
  end
end
