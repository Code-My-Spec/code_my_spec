defmodule CmsHarness.ChannelClientJoinTunnelTest do
  @moduledoc """
  2026-09-29 follow-up, Harness session: this project's own after-promote
  recipe restarts the harness BEAM 13-30s after every promote (see
  `CmsHarness.AppInstance`'s own `ensure_tunnel/3` moduledoc), which took a
  main copy's harness-held tunnel down with it. Nothing brought it back on
  its own — the next `ensure_app_running`/`restart_app` would have, but
  nothing calls one unprompted, so a promoted copy's public preview stayed
  down until an operator or agent happened to ask for its app again.
  Reproduced live: promoting this project's own worktree left metric_flow's
  preview answering 530 until `ensure_app_running` was called by hand.

  `HarnessProjectChannel`'s join reply now carries the same "told fresh"
  `tunnel` an app-ensure does (see its own `tunnel_for/1`), and
  `ChannelClient.handle_join/3` acts on it via
  `CmsHarness.AppInstance.ensure_tunnel_only/2` — which is the one thing
  this file proves: the tunnel comes back from the join alone, with no
  `ensure_app_running`/`restart_app` call anywhere in the picture.

  Same "no socket, no server, no network" shape as
  `ChannelClientTransportTest` — `AppInstance`'s runner is the only thing
  faked, per this project's "no live shell-outs in tests" rule.
  """

  use ExUnit.Case, async: true

  import CmsHarnessTest.AppInstanceHelpers, only: [install_app_instance_runner: 1]

  alias CmsHarness.Project.ChannelClient
  alias CmsHarnessTest.FakeAppInstanceRunner

  @tunnel %{
    "hostname" => "preview-3d7fe72b.codemyspec.com",
    "tunnel_id" => "tunnel-6227",
    "tunnel_secret" => "s3cret",
    "account_tag" => "acct-1"
  }

  setup do
    Process.put({CmsHarness.Project.Transport, :impl}, CmsHarness.Project.Transport.Test)
    Process.put({CmsHarness.Project.Transport.Test, :owner}, self())
    install_app_instance_runner([])
    :ok
  end

  defp socket(root) do
    %Slipstream.Socket{
      assigns: %{
        joined: true,
        refused: nil,
        topic: "harness_project:p1",
        project: %{id: "p1", root: root, working_copy_id: "wc-1"}
      }
    }
  end

  defp tunnel_calls,
    do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:start_tunnel, _}, &1))

  defp launch_calls, do: Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

  test "a join carrying a tunnel starts it, with no ensure_app_running or restart_app anywhere" do
    sock = socket("/tmp/join-tunnel")

    {:ok, _joined} = ChannelClient.handle_join("harness_project:p1", %{"tunnel" => @tunnel}, sock)

    assert [{:start_tunnel, [creds, origin]}] = tunnel_calls()
    assert creds.hostname == "preview-3d7fe72b.codemyspec.com"
    assert creds.tunnel_id == "tunnel-6227"
    assert creds.tunnel_secret == "s3cret"
    assert creds.account_tag == "acct-1"
    assert origin == "http://127.0.0.1:4000"

    assert launch_calls() == [],
           "the tunnel came back through the join alone; the app was never asked to launch"
  end

  test "a join with no tunnel starts nothing" do
    sock = socket("/tmp/join-tunnel-none")

    {:ok, _joined} = ChannelClient.handle_join("harness_project:p1", %{}, sock)

    assert tunnel_calls() == []
  end
end
