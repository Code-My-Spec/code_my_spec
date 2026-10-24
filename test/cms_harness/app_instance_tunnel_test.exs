defmodule CmsHarness.AppInstanceTunnelTest do
  @moduledoc """
  2026-09-29, John: "the harness should hold the tunnel, not the generated
  app." `AppInstance` is told a serving copy's tunnel credentials fresh on
  every `ensure_app_running`/`restart_app`, the same "told, never remembered"
  wire `HarnessProjectChannel.put_main/2` already uses for `main` itself —
  since story 1117 every copy on a machine is told the machine's one tunnel,
  and `CmsHarness.AppInstance`'s own `ensure_tunnel/3` holds whatever it is
  handed — the runner keeps one connector per tunnel.

  Same rig story 1108's own criteria use: a real `ChannelClient` against
  `CmsHarnessTest.FakeServer`, `AppInstance` behind a scripted
  `FakeAppInstanceRunner` — no real `cloudflared`, no real OS process.
  """

  # Sync: `app_instance_rig` sets application env.
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  @tunnel %{
    "hostname" => "preview-main.codemyspec.com",
    "tunnel_id" => "tunnel-1",
    "tunnel_secret" => "s3cret",
    "account_tag" => "acct-1"
  }

  defp push_with(payload, event \\ "ensure_app_running"),
    do: push_app_event_with(event, payload)

  defp tunnel_calls,
    do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:start_tunnel, _}, &1))

  defp stop_tunnel_calls,
    do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:stop_tunnel, _}, &1))

  defp launch_calls, do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

  describe "a confirmed-main copy told a tunnel" do
    test "starts it, pointed at its own origin" do
      %{root: _root} = app_instance_rig(database_exists?: true)

      push_with(%{"main" => true, "tunnel" => @tunnel})

      assert [{:start_tunnel, [creds, origin]}] = tunnel_calls()
      assert creds.hostname == "preview-main.codemyspec.com"
      assert creds.tunnel_id == "tunnel-1"
      assert creds.tunnel_secret == "s3cret"
      assert creds.account_tag == "acct-1"
      assert origin =~ ~r|^http://127\.0\.0\.1:\d+$|
    end

    test "does not start a second one on the next ensure_app_running for the same tunnel" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true, "tunnel" => @tunnel})
      push_with(%{"main" => true, "tunnel" => @tunnel})

      assert length(tunnel_calls()) == 1,
             "an already-running tunnel for the same credentials was started again"
    end

    test "swaps to new credentials when re-provisioned" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true, "tunnel" => @tunnel})
      other = %{@tunnel | "tunnel_id" => "tunnel-2", "tunnel_secret" => "different"}
      push_with(%{"main" => true, "tunnel" => other})

      assert length(tunnel_calls()) == 2

      assert length(stop_tunnel_calls()) == 1,
             "the old tunnel was left running instead of being stopped before the new one started"
    end
  end

  describe "a copy handed the machine's tunnel (story 1117)" do
    test "runs it whether or not it is main" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => false, "tunnel" => @tunnel})

      assert [{:start_tunnel, [%{tunnel_id: "tunnel-1"}, _origin]}] = tunnel_calls(),
             "every copy on a machine is handed the machine's one tunnel; the runner " <>
               "keeps one connector per tunnel, so a copy that is not main runs it too"
    end

    test "handed none on a later request, leaves the shared connector running" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true, "tunnel" => @tunnel})
      assert tunnel_calls() != []

      push_with(%{"main" => false}, "restart_app")

      assert stop_tunnel_calls() == [],
             "one copy losing its tunnel stopped the connector that carries every other " <>
               "copy's address on the machine"
    end
  end

  describe "main with no tunnel of its own" do
    test "starts nothing" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true})

      assert tunnel_calls() == []
    end
  end

  describe "telling the launched app which side holds the tunnel" do
    test "a DB-backed main is launched told the harness holds it" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true, "tunnel" => @tunnel})

      assert [
               {:launch,
                [_root, _port, _https, _db, _log, true, true, "preview-main.codemyspec.com"]}
             ] =
               launch_calls()
    end

    test "main with no DB-backed tunnel is launched told to keep running its own" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true})

      assert [{:launch, [_root, _port, _https, _db, _log, true, false, nil]}] = launch_calls()
    end

    test "a non-main copy is always launched told the harness does not hold one" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => false})

      assert [{:launch, [_root, _port, _https, _db, _log, false, false, nil]}] = launch_calls()
    end
  end
end
