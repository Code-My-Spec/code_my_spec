defmodule CodeMySpec.Provisioning.InboundProbeDefaultTest do
  @moduledoc """
  What the inbound step does about a probe address when nobody supplies one.

  Issue 59f366cc: `default_inbound_probe/3` used to fall back to
  `owner_address/2`, which invented a local part — `inbox@<domain>` recorded
  as a **local** `Mail.Mailbox`, or the operator's own local part — and tried
  it. Resend delivers only to addresses configured for a domain through its
  own dashboard (86648e6e), and neither guess was ever one of those, so the
  fallback failed delivery on every fresh domain and reported "the message
  never arrived" — which reads as a broken inbox rather than as what it
  actually was: no address was ever given, and setup never asked for one.

  The code already had the honest path for this — `{:error,
  :no_probe_address}`, pausing with instructions — but the `owner_address`
  fallback pre-empted it by guessing instead of leaving the address absent.
  This file is the regression: without an override, the step now takes that
  pause rather than guessing.

  Against fakes rather than cassettes, because the claim is about *our*
  decision before any provider is asked anything, not about what a real
  Resend account does — see `test/spex/TESTING_PROVISIONING.md`. Reaching
  `prove_delivery/4` needs the domain created, its webhook set up, its MX
  published to Cloudflare and its records verified, all of which
  `CodeMySpecSpex.Case.fake_providers/1` fakes; `Wait.sleep/1` is a no-op
  under `MIX_ENV=test` (`config/test.exs`), so none of that polling costs
  real time here.

  `async: false`: `fake_providers/1` puts `Req.Test` in shared mode, which is
  global to the VM rather than scoped to this test's process.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.Case, only: [fake_providers: 1, zone_exists: 2]

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Steps

  @domain "inbound-default-drill.example.com"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | environment: Environment.new(:local, tmp)}

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @domain})

    {:ok, scope: %{scope | active_project: project}}
  end

  setup :fake_providers

  setup context do
    zone_exists(context, @domain)
    :ok
  end

  describe "no override supplied" do
    test "pauses asking for an address instead of guessing one", ctx do
      assert {:paused, message} = Steps.run(:inbound, ctx.scope, [])

      assert message =~ "setup will not guess one"

      refute message =~ "never arrived",
             "a guessed address that fails delivery reads as a broken inbox; " <>
               "no address at all should read as a missing precondition instead"
    end
  end

  describe "an explicit override" do
    test "still proves delivery, unaffected by the fallback's removal", ctx do
      to = "sam@#{@domain}"

      assert {:ok, resources} = Steps.run(:inbound, ctx.scope, inbound_probe_to: to)

      assert Enum.any?(resources, &(&1[:kind] == "inbound_proof" and &1[:location] == to)),
             "expected a recorded proof of delivery to #{to}, got #{inspect(resources)}"
    end

    # 04349864: Resend hands back a webhook's `signing_secret` only from the
    # create call, never from list/get — nothing ever captured or threaded
    # it, so ResendWebhookController on the deployed app always fell back to
    # its own graceful no-secret-configured path (skip verification) instead
    # of actually verifying requests came from Resend.
    test "threads the webhook's signing secret into every environment's secrets", ctx do
      to = "sam@#{@domain}"

      assert {:ok, resources} = Steps.run(:inbound, ctx.scope, inbound_probe_to: to)

      secret_locations =
        resources
        |> Enum.filter(&(&1[:kind] == "secret"))
        |> Enum.map(& &1[:location])

      environments = CodeMySpec.Provisioning.EnvironmentRepository.names(ctx.scope)
      assert environments != [], "this test is meaningless with no environments to seed"

      for environment <- environments do
        assert "#{environment}/RESEND_WEBHOOK_SECRET" in secret_locations,
               "expected a recorded secret resource for #{environment}, got " <>
                 inspect(secret_locations)
      end
    end
  end
end
