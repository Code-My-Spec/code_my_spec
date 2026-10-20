defmodule CodeMySpec.Requirements.ASlowDrainStillSettlesTheGraphTest do
  @moduledoc """
  Issue e3c09c4d: after a landing the projector seeds every vantage (about a
  minute, longer under load), and a reader whose drain call timed out gave up at
  once: eight warnings in a minute, and 1055 read a stale `story_promoted` until a
  recompute. A timed-out call is not a drain that did not happen — it is still in
  the projector's mailbox — so the reader waits again, a bounded number of times.

  Sync: the call timeout and attempts are application config, read by every
  reader in the node.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.IncrementalGraph

  setup do
    scope = full_scope_fixture()
    {:ok, pid} = IncrementalGraph.ensure_projecting(scope)

    previous =
      for key <- [:graph_settle_timeout_ms, :graph_settle_attempts],
          do: {key, Application.get_env(:code_my_spec, key)}

    Application.put_env(:code_my_spec, :graph_settle_timeout_ms, 60)
    Application.put_env(:code_my_spec, :graph_settle_attempts, 4)

    on_exit(fn -> Enum.each(previous, &restore/1) end)

    %{scope: scope, projector: pid}
  end

  defp restore({key, nil}), do: Application.delete_env(:code_my_spec, key)
  defp restore({key, value}), do: Application.put_env(:code_my_spec, key, value)

  # The projector is suspended, so the reader's call outlives its timeout.
  defp settle_suspended(%{scope: scope, projector: pid}, suspended_for_ms, reader_fun) do
    :sys.suspend(pid)
    reader = Task.async(fn -> reader_fun.(scope.active_project_id) end)
    Process.sleep(suspended_for_ms)
    :sys.resume(pid)
    Task.await(reader, 5_000)
  end

  test "a drain slower than the call timeout still ends with a settled graph", ctx do
    # Three timeouts' worth of suspension; four attempts of 60ms outlast it.
    assert settle_suspended(ctx, 130, &IncrementalGraph.settle/1) == :ok
  end

  test "a projector that stays silent through every attempt is still unsettled", ctx do
    error = settle_suspended(ctx, 400, &catch_error(IncrementalGraph.settle(&1)))

    assert %RuntimeError{message: message} = error
    assert message =~ "did not complete"
  end
end
