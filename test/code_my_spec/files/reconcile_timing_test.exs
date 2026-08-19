defmodule CodeMySpec.Files.ReconcileTimingTest do
  @moduledoc """
  A reconcile that fails says so, in this module's own vocabulary.

  The absence of this cost a wedged harness. `Repo.transaction/2` raises on
  timeout rather than returning an error tuple, so the crash carried the
  connection's words ("tcp recv: timeout") and none of ours — no file count, no
  working copy, not the word "reconcile". Three frames later it surfaced as a
  closed channel, which the harness reported as a server crash, and the only
  visible symptom was a process pinned at 126% CPU rejoining forever until it
  was killed by hand. Issue `5be796f2`.

  What is asserted here is the instrument, not the theory. Whether concurrent
  reconciles are what pushed that transaction past its limit is still a
  hypothesis; this only proves that when the transaction dies, the log names
  what died — and that nothing was swallowed on the way.
  """
  # Synchronous because it lowers the primary log level, which is global.
  #
  # The duration line is :info by design — that is the level people read — and
  # the suite runs at :warning, so it is filtered before reaching any handler.
  # `capture_log/2`'s `:level` selects among messages that already got through
  # rather than letting more through, and a per-process level did not lift the
  # primary gate either. Lowering it globally is the thing that works, and it
  # costs one non-async module.
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog

  require Logger

  alias CodeMySpec.Files.FileSync
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)

    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    {:ok, scope: full_scope_fixture()}
  end

  defp observation(path) do
    %{
      path: path,
      role: :implementation,
      mtime: DateTime.utc_now(),
      size: 42,
      fingerprint: "reconcile-timing-#{path}"
    }
  end

  test "a completed reconcile records how long it took", %{scope: scope} do
    log =
      capture_log(fn ->
        FileSync.reconcile_and_project(scope, [observation("lib/timing_probe.ex")])
      end)

    assert log =~ "[FileSync] reconciled 1 observations"

    assert log =~ ~r/in \d+ms/,
           "a duration with no number is not a measurement, and the whole point " <>
             "of this line is to be able to see one transaction getting slower"
  end

  test "a reconcile that raises is named before it crashes, and still crashes", %{scope: scope} do
    log =
      capture_log(fn ->
        assert_raise KeyError, fn ->
          FileSync.reconcile_and_project(scope, [%{}])
        end
      end)

    assert log =~ "reconcile of 1 observations"
    assert log =~ "FAILED after"
    assert log =~ "5be796f2"

    assert log =~ "60000ms",
           "the timeout has to appear beside the elapsed time — a duration alone " <>
             "does not tell a reader whether it hit the limit or died some other way"
  end
end
