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

  # Fixed addresses, so the DNS bodies are the same every time.
  # Documentation-range (RFC 5737), which cannot be mistaken for a real host if
  # one of these records ever outlives its teardown.
  @environment_ips [{"prod", "192.0.2.20"}, {"uat", "192.0.2.21"}]
  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # Fakes rather than cassettes. Both halves of this criterion are already
  # about us rather than about the world: the first asserts what we *published*
  # — unproxied records — and the second runs against `stage_certificate/1`,
  # which injects the issuance. Nothing here was ever asking Let's Encrypt for
  # anything, so the cassettes were recording our own calls to Cloudflare and
  # little else.
  setup :fake_providers

  spex "The records let the proxy get its certificate" do
    scenario "the challenge reaches the server and the certificate is issued" do
      given_ "the DNS step has created the records for an environment", context do
        # Staged before anything runs. The probe is read out of
        # `:provisioning_step_opts` when the step executes, and the step
        # executes in the LiveView's process — so staging it in the `when_`,
        # immediately before the click, is a race the click can win.
        stage_certificate(context)

        view = mount_provisioning(context)

        # Set after the mount: a domain present at mount makes `load/2` read the
        # mail panel, which calls Resend and the mount is outside every
        # cassette.
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        # DNS points a name at a server, so there has to be an address — but not
        # a box. `environment_ip/3` uses the environment's own `ip` when it has
        # one and only asks Hetzner when it does not, so seeding it skips the
        # server step entirely.
        for {name, ip} <- @environment_ips do
          CodeMySpecSpex.Fixtures.seed_environment_ip(context.scope, name, ip)
        end

        view
        |> element("[data-test='setup-step'][data-step='dns'] [data-test='run-step']")
        |> render_click()

        CodeMySpecSpex.Case.await_step(view, :dns)

        {:ok, context |> Map.put(:view, view) |> Map.put(:dns_html, render(view))}
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
        CodeMySpecSpex.Case.run_step_interaction(context.view, :tls, "prod")
        CodeMySpecSpex.Case.await_step(context.view, :tls, "prod", 600)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the certificate is issued", context do
        assert context.html =~ ~r/data-step="tls"[^>]*data-state="done"/,
               "expected certificate issuance to succeed against the records setup wrote"

        {:ok, context}
      end
    end
  end
end
