defmodule CodeMySpecSpex.Story969.Criterion8025Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8025 — The signing and bounce records resolve publicly.

  Every record the mail provider asks for is published and resolves from a
  public resolver. Writing a record into Cloudflare is not the same as
  that record being visible to the world — and the provider's verifier is
  in the world.

  The record set as of 2026: a DKIM TXT at `resend._domainkey`, an MX at
  `send`, and an SPF TXT at `send`. Older guidance describing three
  `resend*._domainkey` CNAMEs plus an apex SPF include is stale, so this
  spec asserts against whatever the provider actually returned rather than
  a hardcoded list.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "resend_domain_records_published_and_resolved"

  # Registering the sending domain and mounting the page are real provider
  # calls. Outside a cassette they reach the live API while recording and the
  # network while replaying, so the page knew about a verified domain when
  # recording and nothing when replaying.
  @given_cassette "969_8025_verified_domain"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The signing and bounce records resolve publicly" do
    scenario "each record the provider asked for resolves from a public resolver" do
      given_ "a domain of Sam's that the provider has never seen", context do
        # Its own subdomain. Every criterion in this story used one shared name,
        # so whichever ran second found the first's sending domain already
        # registered and *adopted* it — and an adopted resource is never torn
        # down. Recorded alone each one passed; run together they replayed each
        # other's state.
        _project = own_domain(context.project, "c8025.astralbi.com")
        tear_down_after(context.scope, [:email])

        # Nothing is published here on purpose. Publishing is the step's job
        # (rule 32d294dc), and a fixture that did it first left the step with
        # nothing to do but adopt records already in place — which is how the
        # step shipped unable to publish at all while this criterion stayed
        # green.
        #
        # Nothing probes these names beforehand either. A resolver asked for a
        # name that does not exist yet caches the absence for the zone's SOA
        # negative TTL, and the record would then be invisible for half an hour
        # after it was written.
        view =
          with_provider_cassette(@given_cassette, fn ->
            {:ok, view, _html} =
              live(context.conn, "/app/projects/#{context.project.id}/provisioning")

            view
          end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the email step registers the domain and publishes what it asks for", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "each one resolves from a public resolver", context do
        records =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='mail-dns-record']")

        # Anchor: records were published at all.
        assert records != [], "expected the email step to record the DNS records it published"

        for record <- records do
          name = record |> Floki.attribute("data-name") |> List.first()
          resolved = record |> Floki.attribute("data-resolved") |> List.first()

          assert resolved == "true",
                 "expected #{name} to resolve from a public resolver, got resolved=#{inspect(resolved)}"
        end

        {:ok, Map.put(context, :records, records)}
      end

      then_ "the bounce records sit on the send subdomain, not the apex", context do
        # This is the boundary that keeps 974's inbound apex MX safe. A
        # bounce MX written to the apex would silently take over inbound
        # delivery.
        mx_names =
          context.records
          |> Enum.filter(&((&1 |> Floki.attribute("data-type") |> List.first()) == "MX"))
          |> Enum.map(&(Floki.attribute(&1, "data-name") |> List.first()))

        assert mx_names != [], "expected a bounce MX record among those published"

        for name <- mx_names do
          assert name =~ ~r/^send/,
                 "expected the bounce MX on the send subdomain so apex inbound is untouched, got #{inspect(name)}"
        end

        {:ok, context}
      end
    end
  end
end
