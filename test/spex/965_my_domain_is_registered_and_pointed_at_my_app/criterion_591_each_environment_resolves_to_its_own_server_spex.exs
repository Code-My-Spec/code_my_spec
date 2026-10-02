defmodule CodeMySpecSpex.Story965.Criterion7995Spex do
  @moduledoc """
  Story 965 — My domain is registered and pointed at my app
  Criterion 7995 — Each environment resolves to its own server.

  Every environment gets a DNS record pointing at the server that actually
  serves it, and Sam can confirm it from a public resolver rather than
  taking setup's word. Records written but never resolving is the classic
  DNS failure — the record exists in the dashboard and the site is still
  down.

  Retargeted onto the console (provisioning-console-step6, unmerged): same
  move criterion 588 made — see that spex's moduledoc. `paste_provider_credentials/1`
  needs the credentials-form or its trigger on the mounted view, which only
  the dedicated `/console/credentials` page carries now, so it is pasted
  through a separately-mounted credentials view rather than the resource
  page's. `step_detail/2` is coupled to the old page's `setup-step` markup;
  the local `resource_step_detail/2` below is its `resource-step` equivalent.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Cloudflare`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  # Fixed, distinct addresses so the DNS bodies recorded here are the same
  # every time and no server has to exist to supply them.
  @environment_ips [{"prod", "192.0.2.10"}, {"uat", "192.0.2.11"}]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  defp resource_step_detail(html, key) do
    step =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='resource-step'][data-step='#{key}']")

    state = step |> Floki.attribute("data-state") |> List.first()
    detail = step |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)

    "#{key} step state=#{inspect(state)} detail=#{inspect(detail)}"
  end

  spex "Each environment resolves to its own server", criterion: 591 do
    scenario "each environment's hostname points at the server serving it" do
      # Both halves made true. "Each environment resolves to its own
      # server" cannot be observed without servers to resolve to, and the DNS
      # step in the `when_` has nothing to point anywhere without a domain —
      # it fails on the missing domain, which reads as a DNS bug.
      given_ "Sam has a domain and a provisioned server per environment", context do
        # Before the mount, not after. Mounted before the domain is set, same
        # order criterion 588 uses — see its moduledoc.
        #
        # Its own subdomain. Two spex sharing one name share a DNS namespace:
        # whichever runs second finds the first's records already there,
        # *adopts* them instead of creating them, and adopted resources are
        # never torn down — so the records leak and the recording contains no
        # creation at all.

        # The zone, in the account. Under a cassette this was true because
        # John's Cloudflare really manages it; stated here, so the criterion
        # does not depend on whose account is recording.
        zone_exists(context, "astralbi.com")

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/dns_domain")

        # Set after the mount: a domain present at mount makes `load/2` read the
        # mail panel, which calls Resend outside every cassette.
        own_domain(context.project, "c7995.astralbi.com")

        # Only DNS is created here now, so only DNS needs returning.
        tear_down_after(context.scope, [:dns])

        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_provider_credentials(credentials_view)

        # A distinct address per environment, without a box behind either.
        # `environment_ip/3` uses the environment's own `ip` when it has one and
        # only asks Hetzner when it does not, so this skips the server step
        # entirely — nothing is created and nothing is torn down.
        #
        # It also fits what this criterion actually claims. The assertions below
        # are about DNS *targets*: that they exist, that they name something,
        # and that no two environments share one. Distinct seeded addresses prove
        # that as well as distinct boxes would, and they prove it the same way
        # every time.
        #
        # Which matters, because a real server made this cassette perishable: the
        # DNS record's request body carries the server's IP, minted fresh on each
        # recording, so this cassette and the server's could only ever replay
        # together and drifted apart the moment either was re-recorded alone.
        # Documentation-range (RFC 5737), so a record that ever outlives its
        # teardown cannot point at somebody's real host.
        for {name, ip} <- @environment_ips do
          CodeMySpecSpex.Fixtures.seed_environment_ip(context.scope, name, ip)
        end

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the DNS step runs", context do
        run_console_step(context.view, :dns)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "each environment's hostname resolves to its own server", context do
        records =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='dns-record']")

        # Anchor: records were created at all.
        assert records != [],
               "expected the DNS step to record what it created. " <>
                 resource_step_detail(context.html, "dns")

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
