defmodule CmsHarness.AppInstanceTunnelTest do
  @moduledoc """
  2026-09-29, John: "the harness should hold the tunnel, not the generated
  app." `AppInstance` is told a serving copy's tunnel credentials fresh on
  every `ensure_app_running`/`restart_app`, the same "told, never remembered"
  wire `HarnessProjectChannel.put_main/2` already uses for `main` itself —
  see that module's `put_tunnel/2` for why only a confirmed-main copy is
  ever told one, and `CmsHarness.AppInstance`'s own `ensure_tunnel/3` for
  the harness-side half of the same rule.

  Same rig story 1108's own criteria use: a real `ChannelClient` against
  `CmsHarnessTest.FakeServer`, `AppInstance` behind a scripted
  `FakeAppInstanceRunner` — no real `cloudflared`, no real OS process.
  """

  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner
  alias CmsHarnessTest.FakeServer

  @tunnel %{
    "hostname" => "preview-main.codemyspec.com",
    "tunnel_id" => "tunnel-1",
    "tunnel_secret" => "s3cret",
    "account_tag" => "acct-1"
  }

  defp push_with(payload, event \\ "ensure_app_running") do
    ref = FakeServer.push_app_event(event, payload)
    result_event = String.to_existing_atom("#{event}_result")

    receive do
      {^result_event, %{"ref" => ^ref} = reply} -> reply
    after
      5_000 -> flunk("no #{result_event} for ref #{ref}")
    end
  end

  defp tunnel_calls, do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:start_tunnel, _}, &1))
  defp stop_tunnel_calls, do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:stop_tunnel, _}, &1))

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

  describe "a copy demoted from main" do
    test "stops the tunnel it was holding" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true, "tunnel" => @tunnel})
      assert tunnel_calls() != []

      push_with(%{"main" => false}, "restart_app")

      assert length(stop_tunnel_calls()) == 1,
             "a demoted main kept its old tunnel running — exactly the stray-connector shape this project has already shipped one fix for"
    end
  end

  describe "a non-main copy" do
    test "is never told to run a tunnel, even one sent to it directly" do
      app_instance_rig(database_exists?: true)

      # Not a real production shape (the channel never sends `tunnel` without
      # `main: true` — see `HarnessProjectChannel.put_tunnel/2`) — this is
      # `AppInstance`'s own defense in depth, exercised directly.
      push_with(%{"main" => false, "tunnel" => @tunnel})

      assert tunnel_calls() == [],
             "a non-main copy started a tunnel of its own — criterion 1586/1587's whole " <>
               "premise is that only main ever runs a connector"
    end
  end

  describe "main with no tunnel of its own" do
    test "starts nothing" do
      app_instance_rig(database_exists?: true)

      push_with(%{"main" => true})

      assert tunnel_calls() == []
    end
  end
end
