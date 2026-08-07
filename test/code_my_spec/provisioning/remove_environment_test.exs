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

  alias CodeMySpec.Provisioning.{EnvironmentRepository, Teardown}

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
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
        EnvironmentRepository.put(scope, "qa2", %{
          host: "qa2.example.com",
          server_name: "proj-qa2",
          ip: "5.161.213.9"
        })

      assert {:ok, removed} =
               Teardown.environment(scope, "qa2", teardown: recorder())

      assert drain() == ["dns_record", "server"],
             "the record has to go before the address is released, or it points at somebody else's box"

      assert length(removed) == 2
      refute EnvironmentRepository.get(scope, "qa2")
    end
  end

  describe "removing an environment with nothing provisioned" do
    test "deletes the row and reports nothing removed", %{scope: scope} do
      {:ok, _} = EnvironmentRepository.put(scope, "qa3", %{})

      assert {:ok, []} = Teardown.environment(scope, "qa3", teardown: recorder())
      assert drain() == []
      refute EnvironmentRepository.get(scope, "qa3")
    end
  end

  describe "when a provider refuses" do
    # The row goes anyway. An environment nobody can see is worse than one
    # whose leftovers are named — the row is the only thing that still knows
    # which host and which server to go looking for, so it is reported rather
    # than kept.
    test "still deletes the row and names what survived", %{scope: scope} do
      {:ok, _} =
        EnvironmentRepository.put(scope, "qa4", %{host: "qa4.example.com", server_name: "p-qa4"})

      refuse = fn _scope, resource ->
        if resource.kind == "server", do: {:error, resource}, else: {:ok, resource}
      end

      assert {:error, {:left_behind, [left]}, [removed]} =
               Teardown.environment(scope, "qa4", teardown: refuse)

      assert left.kind == "server"
      assert removed.kind == "dns_record"
      refute EnvironmentRepository.get(scope, "qa4")
    end
  end

  test "an environment that does not exist is not an error", %{scope: scope} do
    assert {:ok, []} = Teardown.environment(scope, "nope", teardown: recorder())
  end
end
