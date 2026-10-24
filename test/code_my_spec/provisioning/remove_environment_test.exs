defmodule CodeMySpec.Provisioning.RemoveEnvironmentTest do
  @moduledoc """
  The order things are removed in, which is the whole security property.

  Provisioning an environment creates a server and an A record pointing at it.
  Hetzner recycles public IPv4 addresses between customers, so a record left
  pointing at a released address resolves to whoever receives it next — a
  subdomain of the customer's own domain, under their proxy and TLS config,
  answering from a machine they do not own. Removing the record first closes
  that window; releasing the address first opens it.

  Asserted through the `:teardown` seam rather than against real providers,
  for the same reason `run_step/3` takes `:verify` and `:execute` — a claim
  about ordering should not cost a server.

  Lives on `Teardown` rather than `Provisioning` because a test asserts that
  `Provisioning` exposes nothing destructive: a routine that can destroy is a
  routine nobody runs unattended, and `run/3` is meant to be run unattended.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppInstances
  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Teardown
  alias CodeMySpec.ProvisioningPlan.StepRepository

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  test "provider teardown refuses a harness-managed environment", %{scope: scope} do
    {:ok, environment} = Environments.put(scope, "development", %{management: :harness})

    assert {:error, :not_provisioned_environment} =
             Teardown.environment(scope, "development", teardown: recorder())

    assert Environments.get(scope, "development").id == environment.id
    assert drain() == []
  end

  test "confirmed provider removal deletes its runtime receipt and environment", %{scope: scope} do
    {:ok, environment} =
      Environments.put(scope, "uat", %{host: "uat.example.com", server_name: "project-uat"})

    {:ok, instance} =
      AppInstances.record_deployment(scope, environment.id, %{
        confirmed_at: DateTime.utc_now(),
        image: "registry/app:release"
      })

    assert {:ok, removed} = Teardown.environment(scope, "uat", teardown: recorder())
    assert Enum.map(removed, & &1.kind) == ["dns_record", "server"]
    assert drain() == ["dns_record", "server"]
    assert AppInstances.get(scope, instance.id) == nil
    assert Environments.get(scope, "uat") == nil
  end

  test "failed provider removal preserves its runtime receipt and environment", %{scope: scope} do
    {:ok, environment} = Environments.put(scope, "uat", %{server_name: "project-uat"})

    {:ok, instance} =
      AppInstances.record_deployment(scope, environment.id, %{
        confirmed_at: DateTime.utc_now(),
        image: "registry/app:release"
      })

    assert {:error, {:left_behind, [_]}, []} =
             Teardown.environment(scope, "uat",
               teardown: fn _scope, resource -> {:error, resource} end
             )

    assert Environments.get(scope, "uat").id == environment.id
    assert AppInstances.get(scope, instance.id).status == "serving"
    assert AppInstances.get(scope, instance.id).deployment_image == "registry/app:release"
  end

  test "an attached harness instance refuses removal before provider side effects", %{
    scope: scope
  } do
    {:ok, environment} = Environments.put(scope, "uat", %{server_name: "project-uat"})

    {:ok, instance} =
      AppInstances.create(scope, %{
        environment_id: environment.id,
        source_root: "/tmp/checkout",
        port_mode: :configured,
        database_mode: :configured
      })

    assert {:error, :environment_in_use} =
             Teardown.environment(scope, "uat", teardown: recorder())

    assert drain() == []
    assert AppInstances.get(scope, instance.id)
    assert Environments.get(scope, "uat")
  end

  test "a skipped provider resource does not certify removal of a deployed runtime", %{
    scope: scope
  } do
    {:ok, environment} = Environments.put(scope, "uat", %{server_name: "project-uat"})

    {:ok, instance} =
      AppInstances.record_deployment(scope, environment.id, %{confirmed_at: DateTime.utc_now()})

    assert {:error, {:left_behind, [_]}, []} =
             Teardown.environment(scope, "uat",
               teardown: fn _scope, resource -> {:skipped, resource} end
             )

    assert AppInstances.get(scope, instance.id).status == "serving"
    assert Environments.get(scope, "uat")
  end

  test "a runtime without a recorded server cannot be confirmed destroyed", %{scope: scope} do
    {:ok, environment} = Environments.put(scope, "uat", %{host: "uat.example.com"})

    {:ok, instance} =
      AppInstances.record_deployment(scope, environment.id, %{confirmed_at: DateTime.utc_now()})

    assert {:error, :deployment_removal_unconfirmed} =
             Teardown.environment(scope, "uat", teardown: recorder())

    assert drain() == []
    assert AppInstances.get(scope, instance.id).status == "serving"
    assert Environments.get(scope, "uat")
  end

  test "a newer deployment during provider teardown keeps its receipt", %{scope: scope} do
    {:ok, environment} = Environments.put(scope, "uat", %{server_name: "project-uat"})

    {:ok, instance} =
      AppInstances.record_deployment(scope, environment.id, %{
        confirmed_at: DateTime.utc_now(),
        image: "registry/app:old"
      })

    teardown = fn _scope, resource ->
      {:ok, _} =
        AppInstances.record_deployment(scope, environment.id, %{
          confirmed_at: DateTime.utc_now(),
          image: "registry/app:new"
        })

      {:ok, resource}
    end

    assert {:error, :deployment_receipt_changed, [_]} =
             Teardown.environment(scope, "uat", teardown: teardown)

    assert AppInstances.get(scope, instance.id).deployment_image == "registry/app:new"
    assert AppInstances.get(scope, instance.id).status == "serving"
    assert Environments.get(scope, "uat")
  end

  defp recorder do
    owner = self()

    fn _scope, resource ->
      send(owner, {:torn_down, resource.kind})
      {:ok, resource}
    end
  end

  defp drain(acc \\ []) do
    receive do
      {:torn_down, kind} -> drain([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "removing an environment that has a server and a record" do
    test "takes the DNS record before the server", %{scope: scope} do
      {:ok, _} =
        Environments.put(scope, "qa2", %{
          host: "qa2.example.com",
          server_name: "proj-qa2",
          ip: "5.161.213.9"
        })

      assert {:ok, removed} =
               Teardown.environment(scope, "qa2", teardown: recorder())

      assert drain() == ["dns_record", "server"],
             "the record has to go before the address is released, or it points at somebody else's box"

      assert length(removed) == 2
      refute Environments.get(scope, "qa2")
    end
  end

  describe "removing an environment with nothing provisioned" do
    test "deletes the row and reports nothing removed", %{scope: scope} do
      {:ok, _} = Environments.put(scope, "qa3", %{})

      assert {:ok, []} = Teardown.environment(scope, "qa3", teardown: recorder())
      assert drain() == []
      refute Environments.get(scope, "qa3")
    end
  end

  describe "when a provider refuses" do
    # The row goes anyway. An environment nobody can see is worse than one
    # whose leftovers are named — the row is the only thing that still knows
    # which host and which server to go looking for, so it is reported rather
    # than kept.
    test "still deletes the row and names what survived", %{scope: scope} do
      {:ok, _} =
        Environments.put(scope, "qa4", %{host: "qa4.example.com", server_name: "p-qa4"})

      # Refuses everything, so there is no branch anywhere in the stub and no
      # ordering to depend on. What the claim needs is that the row goes even
      # when teardown did not, and that what survived is named — neither of
      # which wants a mixed outcome to demonstrate.
      refuse = fn _scope, resource -> {:error, resource} end

      assert {:error, {:left_behind, left}, []} =
               Teardown.environment(scope, "qa4", teardown: refuse)

      assert Enum.map(left, & &1.kind) == ["dns_record", "server"]
      refute Environments.get(scope, "qa4")
    end
  end

  test "an environment that does not exist is not an error", %{scope: scope} do
    assert {:ok, []} = Teardown.environment(scope, "nope", teardown: recorder())
  end

  # Criterion 7969 is "Sam reads back what he now owns", and removing an
  # environment used to leave every step still claiming its server, database,
  # registry and DNS record — permanently, since only `Teardown.step/3` calls
  # `forget/2`. The page listed three servers where one existed, and a
  # `dns_record` for a name the zone did not answer for (92445d6f).
  describe "what the steps still claim afterwards" do
    setup %{scope: scope} do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: 2,
        resources: [
          %{
            kind: "server",
            location: "hetzner/p-uat",
            identifier: "49.12.189.154 environment=uat",
            origin: "created"
          },
          %{
            kind: "server",
            location: "hetzner/p-prod",
            identifier: "159.69.49.203 environment=prod",
            origin: "created"
          },
          # No marker: the firewall belongs to the project, not to one
          # environment, and outlives any single one.
          %{kind: "firewall", location: "hetzner/p", origin: "created"}
        ]
      })

      Environments.put(scope, "uat", %{host: "uat.example.com", server_name: "p-uat"})

      :ok
    end

    defp locations(scope) do
      StepRepository.get(scope, :server).resources
      |> Enum.map(& &1.location)
      |> Enum.sort()
    end

    test "drops the removed environment's resources", %{scope: scope} do
      Teardown.environment(scope, "uat", teardown: fn _s, r -> {:ok, r} end)

      refute "hetzner/p-uat" in locations(scope),
             "a server whose environment is gone is not a server anybody owns"
    end

    test "keeps the other environment's, and the project's own", %{scope: scope} do
      Teardown.environment(scope, "uat", teardown: fn _s, r -> {:ok, r} end)

      assert locations(scope) == ["hetzner/p", "hetzner/p-prod"],
             "removing one environment took something that was not its own"
    end
  end

  # `environment=uat` must not take `environment=uat2` with it, which a
  # substring match would.
  describe "matching the environment marker" do
    setup %{scope: scope} do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: 2,
        resources: [
          %{
            kind: "server",
            location: "hetzner/p-uat2",
            identifier: "10.0.0.9 environment=uat2",
            origin: "created"
          }
        ]
      })

      Environments.put(scope, "uat", %{host: "uat.example.com", server_name: "p-uat"})

      :ok
    end

    test "does not take an environment whose name merely starts the same", %{scope: scope} do
      Teardown.environment(scope, "uat", teardown: fn _s, r -> {:ok, r} end)

      assert StepRepository.get(scope, :server).resources |> Enum.map(& &1.location) ==
               ["hetzner/p-uat2"],
             "removing uat took uat2's server with it"
    end
  end
end
