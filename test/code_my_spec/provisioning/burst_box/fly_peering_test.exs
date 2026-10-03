defmodule CodeMySpec.Provisioning.BurstBox.FlyPeeringTest do
  @moduledoc """
  `run` is injected, the same shape
  `CodeMySpec.Provisioning.Builder.Remote.ssh_runner/2` produces — this stays
  a unit test over the commands a real box would be told to run, never a
  round trip to one.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.BurstBox.FlyPeering

  defp peer(overrides \\ %{}) do
    Map.merge(
      %{
        private_key: "cHJpdmF0ZWtleQ==",
        address: "fdaa:1:2::3/120",
        peer_public_key: "cHVibGlja2V5",
        endpoint: "fly-gateway.example.com:51820",
        allowed_ips: "fdaa::/16"
      },
      overrides
    )
  end

  describe "config/1" do
    test "renders a wg-quick config carrying every field, address with its own prefix intact" do
      cfg = FlyPeering.config(peer())

      assert cfg =~ "[Interface]"
      assert cfg =~ "PrivateKey = cHJpdmF0ZWtleQ=="
      assert cfg =~ "Address = fdaa:1:2::3/120"
      assert cfg =~ "[Peer]"
      assert cfg =~ "PublicKey = cHVibGlja2V5"
      assert cfg =~ "Endpoint = fly-gateway.example.com:51820"
      assert cfg =~ "AllowedIPs = fdaa::/16"
      assert cfg =~ "PersistentKeepalive = 25"
    end
  end

  describe "apply/2" do
    test "installs wireguard-tools, writes the config as base64, and brings the interface up" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      run = fn [command] ->
        Agent.update(agent, &(&1 ++ [command]))
        {"", 0}
      end

      assert FlyPeering.apply(peer(), run) == :ok

      [install, mkdir, write, chmod, up] = Agent.get(agent, & &1)

      assert install =~ "command -v wg-quick"
      assert install =~ "wireguard-tools"
      assert mkdir == "mkdir -p /etc/wireguard"
      assert write =~ "base64 -d > /etc/wireguard/#{FlyPeering.interface()}.conf"
      assert chmod == "chmod 600 /etc/wireguard/#{FlyPeering.interface()}.conf"
      assert up =~ "wg-quick down #{FlyPeering.interface()}"
      assert up =~ "wg-quick up #{FlyPeering.interface()}"

      # The base64 payload decodes back to exactly the config a box would
      # have been handed directly — proven rather than assumed, since this
      # is the one step where a quoting mistake would be silent.
      ["echo", encoded | _] = String.split(write, " ")
      assert Base.decode64!(encoded) == FlyPeering.config(peer())
    end

    test "stops at the first failing step and reports its status and output" do
      run = fn
        ["command -v wg-quick" <> _] -> {"", 0}
        ["mkdir -p /etc/wireguard"] -> {"permission denied", 1}
        [_other] -> flunk("must not run later steps once an earlier one failed")
      end

      assert FlyPeering.apply(peer(), run) == {:error, {1, "permission denied"}}
    end
  end

  describe "remove/1" do
    test "brings the interface down and removes its config in one idempotent call" do
      run = fn [command] ->
        assert command =~ "wg-quick down #{FlyPeering.interface()}"
        assert command =~ "rm -f /etc/wireguard/#{FlyPeering.interface()}.conf"
        {"", 0}
      end

      assert FlyPeering.remove(run) == :ok
    end

    test "succeeds even when the interface was never up, because the delete is what is judged" do
      run = fn [_command] -> {"WireGuard.so: No such file or directory", 0} end
      assert FlyPeering.remove(run) == :ok
    end

    test "a failure to remove the file itself is reported" do
      run = fn [_command] -> {"rm: cannot remove", 1} end
      assert FlyPeering.remove(run) == {:error, {1, "rm: cannot remove"}}
    end
  end
end
