defmodule CodeMySpec.McpServers.Requirements.Tools.SyncProjectRemoteTest do
  @moduledoc """
  `sync_project` on a working copy this server does not hold.

  Two ways to arrive here and only one was handled. The `cwd: nil` clause caught
  the light harness; everything else fell through to a real scan that reached
  `Environments.Harness.stream_files/3`, which refuses on purpose, and surfaced
  as `Sync failed: {:cannot_scan, :not_supported_on_harness}`. `cwd` is set for
  any resolved scope and is not the claim "there is a working copy here" — the
  same distinction `Validation.do_validate_stop/3` already makes, by re-asking
  as though there were no cwd.

  Both now ask the harness to scan its own disk. The previous answer — "the
  graph is already current, there is no sync step to run" — was true until the
  harness disconnected, at which point watching stops and only a reconnect
  starts a fresh scan. An agent with reason to think the graph was stale had no
  lever, which is what b10c4b46 reported after trying to force a recompute.

  What these pin is that neither shape is an error and both say what happened,
  because a tool that reads as broken is the thing being fixed.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Analysis
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Requirements.Tools.SyncProject

  defp run(scope) do
    frame = %Frame{assigns: %{current_scope: scope}}
    {:reply, response, ^frame} = SyncProject.execute(%{}, frame)
    {response, Enum.map_join(Response.to_protocol(response)["content"], "\n", & &1["text"])}
  end

  # A stand-in for the harness channel: the registry holds the channel process,
  # so registering one is what makes the harness addressable.
  defp registered_channel(harness_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Analysis.register_executor(harness_id, "test:#{System.unique_integer()}")
        send(test, {:registered, self()})

        receive do
          message -> send(test, {:channel_got, message})
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  setup do
    harness_id = "harness-#{System.unique_integer([:positive])}"
    %{scope: %{full_scope_fixture() | active_harness_id: harness_id}, harness_id: harness_id}
  end

  describe "when the working copy is on a harness" do
    # The shape that produced the raw refusal: a cwd is present, so the
    # light-harness clause does not match, and the scan runs into an environment
    # that cannot walk.
    test "a cwd it cannot scan asks the harness rather than failing", ctx do
      _pid = registered_channel(ctx.harness_id)

      scope = %{
        ctx.scope
        | cwd: "/somewhere/on/another/machine",
          environment: %Environment{type: :harness, cwd: "/somewhere/on/another/machine"}
      }

      {response, text} = run(scope)

      refute response.isError,
             "`Sync failed: {:cannot_scan, :not_supported_on_harness}` reads as a broken " <>
               "tool. The call is not wrong, the disk is elsewhere."

      assert text =~ "Rescan requested"
      assert_receive {:channel_got, :rescan}, 1_000
    end

    test "no cwd at all asks the harness too", ctx do
      _pid = registered_channel(ctx.harness_id)

      {response, text} = run(%{ctx.scope | cwd: nil})

      refute response.isError
      assert text =~ "Rescan requested"
      assert_receive {:channel_got, :rescan}, 1_000
    end

    test "it says the graph is not current on return", ctx do
      _pid = registered_channel(ctx.harness_id)

      {_response, text} = run(%{ctx.scope | cwd: nil})

      assert text =~ "Nothing is synced on return from this call",
             "the scan happens on another machine and the manifest arrives after. A " <>
               "reply that implied otherwise would send the agent to re-read a graph " <>
               "that has not moved yet, and read as the rescan having failed."
    end
  end

  describe "when no harness is registered" do
    test "it says so without erroring", ctx do
      {response, text} = run(%{ctx.scope | cwd: nil})

      refute response.isError,
             "there is nothing to ask and nothing went wrong; an error here is a tool " <>
               "reporting a fault that is not one"

      assert text =~ "no harness is currently registered"
    end

    test "and names why /health disagrees", ctx do
      {_response, text} = run(%{ctx.scope | cwd: nil})

      assert text =~ "about its socket",
             "the harness's own /health says connected while the server cannot address " <>
               "it, and an agent that checks health first will otherwise conclude the " <>
               "server is lying"
    end
  end
end
