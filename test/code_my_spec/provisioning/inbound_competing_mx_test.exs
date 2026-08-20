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

  `async: false`: `fake_providers/1` puts `Req.Test` in shared mode, global
  to the VM.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.Case, only: [fake_providers: 1, zone_exists: 2, zone_record_exists: 2]

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Steps

  @domain "competing-mx-drill.example.com"

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
      assert {:paused, message} = Steps.run(:inbound, ctx.scope, inbound_probe_to: "sam@#{@domain}")

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

  describe "no competing MX" do
    test "publishes without asking", ctx do
      assert {:ok, resources} =
               Steps.run(:inbound, ctx.scope, inbound_probe_to: "sam@#{@domain}")

      assert Enum.any?(resources, &(&1[:kind] == "mx_record"))
    end
  end
end
