defmodule CodeMySpec.Embeddings.InFlightCallsTest do
  @moduledoc """
  `call/3` against a real `FLAME.Pool`/`FLAME.LocalBackend` (story 877, item
  1 correction) — no FLAME-internals introspection, so this is the only
  seam left to prove the counting actually tracks a real in-flight call
  rather than something stubbed.

  Every test gets its own pool name (`unique_pool/0`), never the real
  `CodeMySpec.EmbedPool`, so this stays `async: true` and never collides
  with another test's globally-named pool.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Embeddings.InFlightCalls

  defp unique_pool, do: :"in_flight_calls_test_pool_#{System.unique_integer([:positive])}"

  defp start_pool!(pool) do
    start_supervised!({FLAME.Pool, name: pool, min: 0, max: 2, backend: FLAME.LocalBackend})
    pool
  end

  describe "any_in_flight?/1" do
    test "false for a pool nothing has ever called through" do
      refute InFlightCalls.any_in_flight?(unique_pool())
    end

    test "true only while a tracked call is actually running, false once it returns" do
      pool = start_pool!(unique_pool())
      test_pid = self()

      spawn(fn ->
        result =
          InFlightCalls.call(pool, fn ->
            send(test_pid, {:inside, self()})
            receive do: (:release -> :done)
          end)

        send(test_pid, {:result, result})
      end)

      assert_receive {:inside, runner_pid}, 2_000
      assert InFlightCalls.any_in_flight?(pool)

      send(runner_pid, :release)

      assert_receive {:result, :done}, 2_000
      refute InFlightCalls.any_in_flight?(pool)
    end

    test "two overlapping calls on the same pool both count, and it only reads idle once both finish" do
      pool = start_pool!(unique_pool())
      test_pid = self()

      for _ <- 1..2 do
        spawn(fn ->
          InFlightCalls.call(pool, fn ->
            send(test_pid, {:inside, self()})
            receive do: (:release -> :ok)
          end)

          send(test_pid, :done)
        end)
      end

      assert_receive {:inside, first}, 2_000
      assert_receive {:inside, second}, 2_000
      assert InFlightCalls.any_in_flight?(pool)

      send(first, :release)
      assert_receive :done, 2_000
      # One of the two is still running.
      assert InFlightCalls.any_in_flight?(pool)

      send(second, :release)
      assert_receive :done, 2_000
      refute InFlightCalls.any_in_flight?(pool)
    end
  end

  describe "call/3" do
    test "returns exactly what FLAME.call returns" do
      pool = start_pool!(unique_pool())

      assert InFlightCalls.call(pool, fn -> :the_result end) == :the_result
    end

    test "decrements even when the called function raises" do
      pool = start_pool!(unique_pool())

      # `link: false` so this surfaces as an `exit` on the caller's own
      # stack (FLAME's own documented behavior) rather than a process-link
      # crash that would take the whole test process down with it — FLAME's
      # default `link: true` links the caller to the remote process
      # specifically so a crash there kills the caller too.
      {error, _stacktrace} =
        catch_exit(InFlightCalls.call(pool, fn -> raise "boom" end, link: false))

      assert %RuntimeError{message: "boom"} = error
      refute InFlightCalls.any_in_flight?(pool)
    end

    # Distinct from "raises" above: that is the *called function* failing
    # inside its own process. This is the runner process itself dying out
    # from under a call still in flight — a killed FLAME runner, a lost
    # node — which reaches the caller as an `exit` with no exception value
    # at all, not a propagated `RuntimeError`. `after` makes no distinction
    # between the two, but John's own "returns to zero on success, error
    # and crash" asked for this proven as its own case rather than assumed
    # covered by the raise test above.
    test "decrements even when the runner process is killed out from under the call" do
      pool = start_pool!(unique_pool())
      test_pid = self()

      spawn(fn ->
        result =
          catch_exit(
            InFlightCalls.call(
              pool,
              fn ->
                send(test_pid, {:runner, self()})
                receive do: (:never -> :unreachable)
              end,
              link: false
            )
          )

        send(test_pid, {:result, result})
      end)

      assert_receive {:runner, runner_pid}, 2_000
      assert InFlightCalls.any_in_flight?(pool)

      Process.exit(runner_pid, :kill)

      assert_receive {:result, _exit_reason}, 2_000
      refute InFlightCalls.any_in_flight?(pool)
    end
  end
end
