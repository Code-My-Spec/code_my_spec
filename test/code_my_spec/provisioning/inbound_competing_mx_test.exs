defmodule CodeMySpec.Provisioning.InboundCompetingMxTest do
  @moduledoc """
  Whether the inbound step checks for a competing MX before publishing.

  Issue 22b0e27c, flagged narratively across three QA passes before being
  filed on its own: `Cloudflare.ensure_dns_record/5` matches an existing
  record by name AND type only. An MX at the target name with different
  content is not "already right" — it falls to the `%{"id" => id} ->
  update_dns_record(...)` branch and gets overwritten by PUT, not added
  alongside. For an apex A record that is `apex_repoint/4`'s exact concern;
  for MX it is worse, because MX genuinely supports more than one record at
  once, so an existing one is not automatically "ours to replace" the way a
  second apex A record would be.

  Against fakes rather than a real zone, for the same reason
  `inbound_probe_default_test.exs` is: the claim is about *our* decision
  before any provider write happens, not about what a real account holds.

  `async: true`: `fake_providers/1` puts `Req.Test` in shared mode, global
  to the VM.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  import CodeMySpecSpex.Case,
    only: [fake_providers: 1, zone_exists: 2, zone_record_exists: 2, zone_records: 1]

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Provisioning.Steps

  @domain "competing-mx-drill.example.com"

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("test")

    scope =
      CodeMySpec.UsersFixtures.put_fixture_execution_context(
        provisioning_scope_fixture(),
        ExecutionContext.new(:local, tmp)
      )

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @domain})

    {:ok, scope: %{scope | active_project: project}}
  end

  setup :fake_providers

  setup context do
    zone_exists(context, @domain)
    :ok
  end

  describe "a competing MX already exists" do
    setup context do
      # `""` is `receiving_records/1`'s own name for the apex receiving
      # record — `qualify("", domain)` resolves it to `@domain`, which is
      # the name this has to be seeded under for the check to find it.
      zone_record_exists(context, %{
        "name" => @domain,
        "type" => "MX",
        "content" => "mx.competing-provider.example",
        "priority" => 5
      })

      :ok
    end

    test "pauses instead of overwriting it", ctx do
      assert {:paused, message} =
               Steps.run(:inbound, ctx.scope, inbound_probe_to: "sam@#{@domain}")

      assert message =~ "mx.competing-provider.example"
      assert message =~ @domain
    end

    test "confirming publishes anyway", ctx do
      assert {:ok, resources} =
               Steps.run(:inbound, ctx.scope,
                 inbound_probe_to: "sam@#{@domain}",
                 confirm_inbound_mx_repoint: true
               )

      assert Enum.any?(resources, &(&1[:kind] == "mx_record"))
    end
  end

  describe "several competing MX records already exist at the same name" do
    # 98156e74: confirming used to skip straight past the check and let
    # `ensure_dns_record/5` do its own name+type lookup, which finds the
    # *first* match — so one confirmed run against a name carrying several
    # competing records (MX genuinely supports more than one, unlike an apex
    # A record) silently overwrote whichever one the provider happened to
    # list first and left the rest standing. Observed live on
    # metric-flow.app: three Cloudflare routes plus one AWS inbound record,
    # and confirming peeled off exactly one per run.
    setup context do
      # None of these match the fake Resend's own inbound target
      # (`inbound-smtp.us-east-1.amazonaws.com` — see `Fakes.Resend`'s
      # `receiving_records/1`), which `ensure_dns_record/5` would correctly
      # treat as already-right content needing only a priority fix, not a
      # competing record to clear.
      for {host, priority} <- [
            {"mail.some-other-provider.example", 2},
            {"route1.mx.cloudflare.net", 3},
            {"route2.mx.cloudflare.net", 45}
          ] do
        zone_record_exists(context, %{
          "name" => @domain,
          "type" => "MX",
          "content" => host,
          "priority" => priority
        })
      end

      :ok
    end

    test "one confirmation clears the whole set, not just the first", ctx do
      assert {:ok, resources} =
               Steps.run(:inbound, ctx.scope,
                 inbound_probe_to: "sam@#{@domain}",
                 confirm_inbound_mx_repoint: true
               )

      assert Enum.any?(resources, &(&1[:kind] == "mx_record"))

      mx_records = ctx |> zone_records() |> Enum.filter(&(&1["type"] == "MX"))

      refute Enum.any?(mx_records, &(&1["content"] == "mail.some-other-provider.example")),
             "a competing record survived a confirmed run: #{inspect(mx_records)}"

      refute Enum.any?(mx_records, &(&1["content"] == "route1.mx.cloudflare.net")),
             "a competing record survived a confirmed run: #{inspect(mx_records)}"

      refute Enum.any?(mx_records, &(&1["content"] == "route2.mx.cloudflare.net")),
             "a competing record survived a confirmed run: #{inspect(mx_records)}"
    end
  end

  describe "no competing MX" do
    test "publishes without asking", ctx do
      assert {:ok, resources} =
               Steps.run(:inbound, ctx.scope, inbound_probe_to: "sam@#{@domain}")

      assert Enum.any?(resources, &(&1[:kind] == "mx_record"))
    end
  end

  # 98156e74: a confirmation is a specific claim — this run replaced every
  # competing record at the name — and `confirm_cleared/5` is what checks
  # that claim actually held, after publishing, before reporting success.
  # `clear_competing_mx/3` already clears everything one listing can see, so
  # there is no way to make a record survive a confirmed run against the
  # fake, which has no concurrent writer to race. Proven directly instead,
  # against `competing_records/3` — the same function both the clear and
  # the post-check call — with the zone shape each of them actually passes
  # it (Cloudflare's own record maps, Resend's `mx_records/1` maps).
  describe "competing_records/3" do
    @zone %{"id" => "zone-1", "name" => @domain}

    test "finds an existing MX at the target name whose content Resend does not want" do
      resend_records = [%{"name" => "", "value" => "inbound-smtp.us-east-1.amazonaws.com"}]

      existing = [
        %{
          "id" => "rec-1",
          "name" => @domain,
          "type" => "MX",
          "content" => "route1.mx.cloudflare.net"
        },
        %{
          "id" => "rec-2",
          "name" => @domain,
          "type" => "MX",
          "content" => "inbound-smtp.us-east-1.amazonaws.com"
        },
        %{"id" => "rec-3", "name" => @domain, "type" => "TXT", "content" => "v=spf1 -all"}
      ]

      assert [%{"id" => "rec-1"}] = Steps.competing_records(@zone, resend_records, existing)
    end

    test "finds nothing once every existing record already matches what Resend wants" do
      resend_records = [%{"name" => "", "value" => "inbound-smtp.us-east-1.amazonaws.com"}]

      existing = [
        %{
          "id" => "rec-2",
          "name" => @domain,
          "type" => "MX",
          "content" => "inbound-smtp.us-east-1.amazonaws.com"
        }
      ]

      assert [] = Steps.competing_records(@zone, resend_records, existing)
    end
  end
end
