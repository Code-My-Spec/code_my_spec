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

  # Its own cassette, not 7995's. A cassette shared by two spex replays one
  # spex's recorded sequence against the other's calls, and sequential matching
  # then fails on whichever makes one more request than the recording did.
  @dns_cassette "965_7996_dns_records_for_certificate"

  # Fixed addresses, so the DNS bodies this records are the same every time.
  # Documentation-range (RFC 5737), which cannot be mistaken for a real host if
  # one of these records ever outlives its teardown.
  @environment_ips [{"prod", "192.0.2.20"}, {"uat", "192.0.2.21"}]
  @cert_cassette "kamal_proxy_certificate_issued"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The records let the proxy get its certificate" do
    scenario "the challenge reaches the server and the certificate is issued" do
      given_ "the DNS step has created the records for an environment", context do
        # Before the mount, not after. The LiveView loads the project into its
        # assigns when it mounts and every step it runs reads that copy, so a
        # domain written to the row afterwards is invisible to it — the DNS step
        # refused with "no domain set on the project" while the row plainly had
        # one, and the criterion read that as a certificate failure.
        #
        # Its own subdomain. Two spex sharing one name share a DNS namespace:
        # whichever runs second finds the first's records already there,
        # *adopts* them instead of creating them, and adopted resources are
        # never torn down — so the records leak and the recording contains no
        # creation at all.

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Set after the mount: a domain present at mount makes `load/2` read the
        # mail panel, which calls Resend outside every cassette.
        own_domain(context.project, "c7996.astralbi.com")

        # Registered *after* the LiveView is mounted, so it runs *before*
        # LiveViewTest tears it down — `on_exit` callbacks run in reverse order
        # of registration. That matters because the sandbox is in shared mode:
        # one connection is checked out and every process borrows it, so once
        # the process holding it exits the connection is gone for good and no
        # retry can get it back. Teardown has to do its reads while the
        # LiveView is still up.
        tear_down_after(context.scope, [:dns])

        paste_provider_credentials(view)

        # DNS points a name at a server, so there has to be an address — but not
        # a box. `environment_ip/3` uses the environment's own `ip` when it has
        # one and only asks Hetzner when it does not, so seeding it skips the
        # server step entirely: nothing is created, nothing is torn down, and no
        # Hetzner cassette is involved.
        #
        # That is what makes this criterion recordable on its own. The DNS
        # record's request body carries the server's IP, and a real server is
        # minted fresh on every recording — so this cassette and the server's
        # could only ever replay together, and recorded two days apart they did
        # not: the bodies wanted 5.161.239.73 while the server cassette handed
        # out something else. A fixed address is the same address next year.
        for {name, ip} <- @environment_ips do
          CodeMySpecSpex.Fixtures.seed_environment_ip(context.scope, name, ip)
        end

        html =
          with_provider_cassette(@dns_cassette, fn ->
            view
            |> element("[data-test='setup-step'][data-step='dns'] [data-test='run-step']")
            |> render_click()

            # A step announces its state over PubSub, and the LiveView reloads
            # when it receives that. `render_click/1` returns before the
            # announcement has been handled, so the reload could land after the
            # cassette block exited — hitting the network instead of the
            # cassette, and taking the LiveView (and its database connection)
            # down with it. Rendering again forces a round-trip, which flushes
            # the pending message while the plug is still installed.
            render(view)
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
        stage_certificate(context)

        html =
          with_provider_cassette(@cert_cassette, fn ->
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
