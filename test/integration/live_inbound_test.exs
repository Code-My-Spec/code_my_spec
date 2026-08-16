defmodule CodeMySpec.LiveInboundTest do
  @moduledoc """
  Proves the `inbound` step against real Resend and real Cloudflare.

  Excluded by default (`:live`). Credentials come in as `CMS_RESEND_TOKEN` and
  `CMS_CLOUDFLARE_TOKEN` rather than being read from the dev database — the
  test runs under the Ecto sandbox, which cannot see dev's rows. Export them
  from a connected dev install:

      mix run -e 'CodeMySpec.Provisioning.LiveCredentials.print()'  # or psql

  ## Why this is a live test rather than a cassette

  Every design decision in the step came from what the API actually returned,
  and each one contradicted the obvious implementation:

  - a receiving domain returns **two** MX records, and the one that looks
    right by type is the sending bounce record
  - Resend names an apex record `""`, not `nil`
  - capabilities can only be set at creation, so an existing domain with
    receiving off cannot be upgraded
  - a webhook can exist, be subscribed to the right event, and be disabled

  A hand-written cassette would have encoded my assumptions, all four of which
  were wrong.

  ## It creates real resources in a real zone

  A subdomain of the project's domain, an MX record, and a webhook — all
  removed in `on_exit`, and the removal is verified rather than assumed.
  """
  use CodeMySpecTest.DataCase, async: true

  @moduletag :live
  @moduletag timeout: 900_000

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.{Cloudflare, Resend}

  # Deliberately not `mail.` — that is the name the step defaults to, and a
  # test that reuses it could delete a real one.
  @subdomain "cms-inbound-proof"

  setup do
    resend = System.get_env("CMS_RESEND_TOKEN")
    cloudflare = System.get_env("CMS_CLOUDFLARE_TOKEN")

    if is_nil(resend) or is_nil(cloudflare) do
      raise "set CMS_RESEND_TOKEN and CMS_CLOUDFLARE_TOKEN to run the live inbound test"
    end

    scope = CodeMySpec.UsersFixtures.full_scope_fixture()

    for {provider, token} <- [resend: resend, cloudflare: cloudflare] do
      {:ok, _} =
        CodeMySpec.Integrations.IntegrationRepository.upsert_integration(scope, provider, %{
          access_token: token,
          refresh_token: nil,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          granted_scopes: [],
          provider_metadata: %{provider_user_id: "live", email: nil, name: "live"}
        })
    end

    domain = System.get_env("CMS_LIVE_DOMAIN", "codemyspec.com")
    name = "#{@subdomain}.#{domain}"

    # Teardown talks to the providers directly rather than through the provider
    # modules: `on_exit` runs after the sandbox connection is checked in, and
    # those modules read the token from the database on every call.
    on_exit(fn -> teardown(resend, cloudflare, domain, name) end)

    %{scope: scope, domain: domain, name: name}
  end

  test "a receiving domain is created with receiving actually enabled", ctx do
    assert {:ok, domain} =
             Resend.ensure_receiving_domain(ctx.scope, ctx.name, region: "us-east-1")

    IO.puts("\n  domain     -> #{domain["name"]} #{inspect(domain["capabilities"])}")

    # Receiving defaults to disabled, so this is the assertion that matters:
    # the capability was requested and the provider honoured it.
    assert Resend.receiving?(domain), "the domain was created without receiving enabled"
    assert Resend.sending?(domain), "creating a receiving domain disabled sending"
  end

  test "only the receiving MX is published, never the sending bounce record", ctx do
    {:ok, created} = Resend.ensure_receiving_domain(ctx.scope, ctx.name, region: "us-east-1")
    {:ok, full} = Resend.get_domain(ctx.scope, created["id"])
    domain = full["data"] || full

    all_mx =
      domain
      |> Resend.records()
      |> Enum.filter(&(String.upcase(to_string(&1["type"])) == "MX"))

    receiving = Resend.mx_records(domain)

    IO.puts("  mx         -> #{length(all_mx)} MX total, #{length(receiving)} for receiving")

    # The whole point: filtering by type alone takes the sending record too,
    # and publishing that as the inbound MX breaks sending and receiving at
    # once (criterion 8032).
    assert length(receiving) < length(all_mx) or length(all_mx) == 1

    for record <- receiving do
      assert record["record"] == "Receiving"
      refute record["value"] =~ "feedback-smtp"
      assert is_integer(record["priority"]), "an MX with no priority will not receive mail"
    end
  end

  test "the step publishes the MX in Cloudflare at the priority Resend asked for", ctx do
    assert {:ok, step} =
             Provisioning.run_step(ctx.scope, :inbound,
               inbound_domain: ctx.domain,
               inbound_subdomain: @subdomain,
               webhook_endpoint: webhook_endpoint(),
               region: "us-east-1"
             )

    assert step.state == :done
    IO.puts("  inbound    -> #{step.state} #{inspect(Enum.map(step.resources, & &1.kind))}")

    mx = Enum.filter(step.resources, &(&1.kind == "mx_record"))
    assert mx != [], "the step recorded no MX record"

    # Read it back out of Cloudflare rather than trusting the write.
    {:ok, zone} = Cloudflare.find_zone(ctx.scope, ctx.domain)
    {:ok, records} = Cloudflare.list_dns_records(ctx.scope, zone["id"])

    published = Enum.filter(records, &(&1["name"] == ctx.name and &1["type"] == "MX"))

    assert published != [], "no MX for #{ctx.name} in the zone"

    for record <- published do
      IO.puts("  published  -> #{record["name"]} MX #{record["content"]} priority #{record["priority"]}")

      assert record["content"] =~ "inbound-smtp",
             "the published MX is not Resend's receiving host"

      assert is_integer(record["priority"])
    end

    # Resend names an apex record "" — passing that through creates a record
    # for the wrong name, which is silent until mail does not arrive.
    refute Enum.any?(published, &(&1["name"] == "" or &1["name"] == ctx.domain)),
           "the MX landed on the wrong name"
  end

  test "an existing but disabled webhook is enabled rather than reported done", ctx do
    endpoint = webhook_endpoint()

    {:ok, webhook} = Resend.ensure_webhook(ctx.scope, endpoint)
    assert webhook["id"]

    # Disable it behind the step's back, exactly as the account already had.
    {:ok, _} =
      Resend.update_webhook_status(ctx.scope, webhook["id"], "disabled")

    {:ok, hooks} = Resend.list_webhooks(ctx.scope)
    disabled = Enum.find(hooks, &(&1["endpoint"] == endpoint))
    assert disabled["status"] == "disabled", "could not set up the disabled case"

    # Verify must not accept it: a disabled webhook looks configured from
    # every angle except the one that counts.
    assert {:ok, :absent} =
             Provisioning.verify(ctx.scope, :inbound,
               inbound_domain: ctx.domain,
               inbound_subdomain: @subdomain,
               webhook_endpoint: endpoint
             )

    {:ok, _} = Resend.ensure_webhook(ctx.scope, endpoint)

    {:ok, hooks} = Resend.list_webhooks(ctx.scope)
    reenabled = Enum.find(hooks, &(&1["endpoint"] == endpoint))

    IO.puts("  webhook    -> #{endpoint} #{reenabled["status"]}")
    assert reenabled["status"] == "enabled"
  end

  defp webhook_endpoint, do: "https://dev.codemyspec.com/webhooks/resend-inbound-proof"

  defp teardown(resend, cloudflare, domain, name) do
    resend_req = fn method, path ->
      Req.request(
        method: method,
        url: "https://api.resend.com" <> path,
        headers: [{"authorization", "Bearer #{resend}"}]
      )
    end

    cf_req = fn method, path ->
      Req.request(
        method: method,
        url: "https://api.cloudflare.com/client/v4" <> path,
        headers: [{"authorization", "Bearer #{cloudflare}"}]
      )
    end

    with {:ok, %{body: %{"data" => domains}}} <- resend_req.(:get, "/domains"),
         %{"id" => id} <- Enum.find(domains, &(&1["name"] == name)) do
      resend_req.(:delete, "/domains/#{id}")
    end

    with {:ok, %{body: %{"data" => hooks}}} <- resend_req.(:get, "/webhooks") do
      for %{"id" => id, "endpoint" => endpoint} <- hooks, endpoint == webhook_endpoint() do
        resend_req.(:delete, "/webhooks/#{id}")
      end
    end

    with {:ok, %{body: %{"result" => zones}}} <- cf_req.(:get, "/zones?name=#{domain}"),
         %{"id" => zone_id} <- List.first(zones),
         {:ok, %{body: %{"result" => records}}} <-
           cf_req.(:get, "/zones/#{zone_id}/dns_records") do
      for %{"id" => id, "name" => record_name} <- records, record_name == name do
        cf_req.(:delete, "/zones/#{zone_id}/dns_records/#{id}")
      end

      # Verified, not assumed — a record left in a production zone is worse
      # than a test that never ran.
      {:ok, %{body: %{"result" => left}}} = cf_req.(:get, "/zones/#{zone_id}/dns_records")

      if Enum.any?(left, &(&1["name"] == name)) do
        IO.warn("live inbound test left DNS records for #{name} behind")
      end
    end
  end
end
