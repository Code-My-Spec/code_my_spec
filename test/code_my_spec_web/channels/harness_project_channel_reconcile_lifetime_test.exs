defmodule CodeMySpecWeb.HarnessProjectChannelReconcileLifetimeTest do
  @moduledoc """
  A reconcile does not outlive the channel that started it.

  `async_nolink` deliberately does not link the task to the channel, so it kept
  running under `TaskSupervisor` after the channel was gone — and the rejoin got
  a fresh channel with empty assigns, saw no reconcile in flight, and started
  another on top of the orphan. `assigns.reconciling` serialises reconciles
  within one channel and cannot see across two.

  That is the join storm in `1aed7edf`: a rejoin every ~1.2s, each starting a
  full reconcile holding a connection for the 9-10s it takes, until the pool is
  exhausted and `insert_all` into `files` dies with "timed out because it queued
  and checked out the connection for longer than 60000ms". The crash closes the
  channel, the close triggers a rejoin, and the next attempt is exactly as slow
  as the last, so it does not self-clear. Fifteen minutes across two working
  copies, ending when the harness was killed by hand.

  None of that path had test coverage, and could not have: `config/test.exs`
  sets `analysis_mode: :inline`, so `accept_manifest/2` reconciles synchronously
  and never spawns the task the bug lives in. These override it.
  """

  # Not async: overrides the global `:analysis_mode`, and the reconcile
  # registry is a node-wide Registry.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Files.ReconcileRegistry
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    previous = Application.get_env(:code_my_spec, :analysis_mode)
    Application.put_env(:code_my_spec, :analysis_mode, :async)
    on_exit(fn -> Application.put_env(:code_my_spec, :analysis_mode, previous) end)

    # The kill logs at :info — it is the healthy path, and warning would cry
    # wolf on every ordinary refresh. The suite runs at :warning, and
    # `capture_log/2`'s `:level` selects among messages that already got
    # through rather than letting more through, so the primary level has to
    # come down for the assertion to see it.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    scope = full_scope_fixture()

    {:ok, _reply, channel} =
      UserSocket
      |> socket("harness_test", %{scope: scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{scope.active_project_id}",
        %{
          "label" => "the harness at /workspace/app",
          "harness_id" => scope.active_harness_id
        }
      )

    %{scope: scope, channel: channel}
  end

  # Enough files that the reconcile is still running when we look. The real one
  # is 4,155 observations and takes seconds; this only has to outlast a
  # `Registry.lookup`.
  defp observations(n) do
    for i <- 1..n do
      %{
        "path" => "lib/demo/mod_#{i}.ex",
        "role" => "implementation",
        "mtime" => "2026-07-28T10:00:00.000000Z",
        "size" => 120,
        "fingerprint" => "fp-#{i}",
        "valid" => true,
        "validation_errors" => %{}
      }
    end
  end

  # The running reconcile's pid, or a failure that says why there is none.
  #
  # Returning `nil` here and letting the caller `refute Process.alive?` would
  # pass for the wrong reason — a reconcile that already finished is
  # indistinguishable from one that was correctly killed, and the second is what
  # this file exists to assert.
  defp await_reconcile_pid(harness_id, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Registry.lookup(ReconcileRegistry, to_string(harness_id)) do
        [{pid, _meta}] -> {:halt, pid}
        [] -> tick()
      end
    end) ||
      flunk("""
      No reconcile was ever observed in the registry.

      Either the manifest did not start one — in which case the async path is
      not being exercised and `:analysis_mode` did not take — or it finished
      faster than a registry lookup. Raise the observation count; do not relax
      the assertion, because "already finished" and "correctly killed" look
      identical from the other side and only one of them is this test's subject.
      """)
  end

  defp tick do
    Process.sleep(5)
    {:cont, nil}
  end

  defp await_death(pid, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if Process.alive?(pid), do: tick(), else: {:halt, true}
    end)
  end

  # Excluded from the default suite, and the reason is not that it is flaky —
  # it is that it cannot be honest inside the sandbox.
  #
  # Its subject is `terminate/2` brutally killing the in-flight reconcile. Under
  # `{:shared, owner}` every process shares one connection, so the kill breaks
  # the connection the very next line needs — `Analysis.fail_in_flight/2`, at
  # `harness_project_channel.ex:835` — and the channel dies with
  # `DBConnection.OwnershipError`. In production the task holds its own pooled
  # connection and the sequence is safe, which is why this is an artifact of the
  # sandbox rather than a defect in what it tests.
  #
  # Measured 2026-08-20: ~3 failures in 10 full-suite runs, none standalone, and
  # every failure reported an ownership error that says nothing about the
  # mechanism under test. A guard that cries wolf a third of the time is one
  # nobody reads.
  #
  # Kept rather than deleted because nothing else covers this: `grep` finds
  # `shutdown_reconcile` and its log line in this file and the channel, nowhere
  # else. What it guards is `1aed7edf` — a rejoin every ~1.2s, each starting a
  # reconcile that holds a connection for 9-10s until the pool is exhausted,
  # 15+ minutes across two working copies, and it does not self-clear because
  # every attempt is as slow as the last.
  #
  # Run it deliberately: `MIX_ENV=test mix test --only real_pool`. The honest
  # cost is that a regression in the kill path is caught later rather than
  # sooner — which, at a 30% false-alarm rate, was already true.
  #
  # See issue 883af150 for the full diagnosis, including the two rival
  # explanations that were tested and eliminated.
  @tag :real_pool
  test "the reconcile dies with the channel that started it", %{
    scope: scope,
    channel: channel
  } do
    push(channel, "observations", %{"observations" => observations(400)})

    pid = await_reconcile_pid(scope.active_harness_id)

    assert Process.alive?(pid),
           "the precondition — there is no point asserting a kill on something already dead"

    # `leave/1` rather than calling `terminate/2` with a hand-built socket: the
    # task is in the channel's *own* assigns, and a fabricated socket carries
    # `reconciling: nil`, so `shutdown_reconcile/1` would find nothing and this
    # would pass without exercising anything.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        ref = leave(channel)
        assert_reply ref, :ok, _payload, 2_000

        assert await_death(pid), """
        The reconcile outlived its channel.

        The rejoin that follows gets a fresh channel with empty assigns, starts a
        second reconcile on top of this one, and each holds a connection until the
        pool is gone. That is the storm, and it does not self-clear because every
        attempt is as slow as the last.
        """
      end)

    assert log =~ "killed the in-flight reconcile",
           "a fix that works silently cannot be told from one that never runs — the " <>
             "test proves the mechanism, this line is the only thing that says it is " <>
             "happening on a real machine"
  end

  test "a second reconcile is skipped while one is already running for this copy", %{
    scope: scope,
    channel: channel
  } do
    # An orphan, standing in for the reconcile of a channel that went away
    # without draining — the case `terminate/2` cannot cover.
    test_pid = self()

    orphan =
      spawn(fn ->
        ReconcileRegistry.mark(scope.active_harness_id, 4155)
        send(test_pid, :marked)
        receive do: (:release -> :ok)
      end)

    assert_receive :marked, 1_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        ref = push(channel, "observations", %{"observations" => observations(3)})
        assert_reply ref, :ok, _reply, 2_000
      end)

    assert log =~ "skipped a reconcile",
           "running two at once for one working copy is what exhausts the pool"

    assert log =~ "4155",
           "the skip has to name what is already running, or a reader cannot tell " <>
             "a healthy skip from a stuck one"

    send(orphan, :release)
  end
end
