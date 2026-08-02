defmodule CodeMySpecSpex.Story965.Criterion7995Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7995 — Each environment resolves to its own server.

  Every environment gets a DNS record pointing at the server that actually
  serves it, and Sam can confirm it from a public resolver rather than
  taking setup's word. Records written but never resolving is the classic
  DNS failure — the record exists in the dashboard and the site is still
  down.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_dns_records_created_per_environment"

  @given_cassette "965_7995_domain_and_servers"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Each environment resolves to its own server" do
    scenario "each environment's hostname points at the server serving it" do
      # Both halves made true. "Each environment resolves to its own
      # server" cannot be observed without servers to resolve to, and the DNS
      # step in the `when_` has nothing to point anywhere without a domain —
      # it fails on the missing domain, which reads as a DNS bug.
      given_ "Sam has a domain and a provisioned server per environment", context do
        view = mount_provisioning(context)
        # Its own subdomain. Two spex sharing one name share a DNS namespace:
        # whichever runs second finds the first's records already there,
        # *adopts* them instead of creating them, and adopted resources are
        # never torn down — so the records leak and the recording contains no
        # creation at all.
        own_domain(context.project, "c7995.astralbi.com")

        # Registered before anything is made: this spex provisions a real
        # server and writes real DNS records, and a recording that fails
        # partway must still not leave a box running or a record pointing at
        # nothing.
        tear_down_after(context.scope, [:dns, :server])

        # Hetzner has no OAuth, so its token is pasted per project — without it
        # the server step stops at `hetzner_not_configured` and the DNS step
        # then has no server to point at, which reads as a DNS failure.
        # Saving a credential proves it with a real provider call, so it
        # belongs inside the cassette.
        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)

          view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the DNS step runs", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='dns'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "each environment's hostname resolves to its own server", context do
        records =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='dns-record']")

        # Anchor: records were created at all.
        assert records != [], "expected the DNS step to record what it created"

        by_env =
          Map.new(records, fn el ->
            {el |> Floki.attribute("data-environment") |> List.first(),
             el |> Floki.attribute("data-target") |> List.first()}
          end)

        assert map_size(by_env) > 0, "expected records tagged by environment"

        for {env, target} <- by_env do
          assert is_binary(target) and target != "",
                 "expected #{env}'s record to name the server it points at"
        end

        # Environments never share a server, so their DNS targets must differ.
        # This assertion was initially left out to accommodate a shared-box
        # start; that was rolled back — UAT and prod always get their own
        # boxes, and prod is simply provisioned later. Two environments
        # resolving to one address would mean UAT traffic reaching production.
        targets = Map.values(by_env)

        assert targets == Enum.uniq(targets),
               "expected each environment to resolve to its own server, got #{inspect(by_env)}"

        {:ok, Map.put(context, :by_env, by_env)}
      end

      then_ "Sam can confirm it from a public resolver", context do
        assert has_element?(context.view, "[data-test='dns-verified'][data-source='resolver']"),
               "expected setup to confirm the records against a public resolver, not just its own write"

        {:ok, context}
      end
    end
  end
end
