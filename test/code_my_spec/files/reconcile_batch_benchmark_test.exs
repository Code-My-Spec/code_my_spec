defmodule CodeMySpec.Files.ReconcileBatchBenchmarkTest do
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files.FileSync
  alias Ecto.Adapters.SQL.Sandbox

  test "measure a cold 5k-file manifest" do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    scope = full_scope_fixture()

    observations =
      for n <- 1..5_000 do
        path = "lib/benchmark/file_#{n}.ex"

        %{
          path: path,
          role: :implementation,
          mtime: ~U[2026-07-28 10:00:00.000000Z],
          size: 120,
          fingerprint: "fp-#{n}",
          valid: true,
          validation_errors: %{}
        }
      end

    handler = "file-sync-benchmark-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :file_sync, :batch],
        fn _, measures, _, _ ->
          send(owner, {:batch_ms, measures.transaction_ms})
        end,
        nil
      )

    started = System.monotonic_time(:millisecond)
    result = FileSync.reconcile_and_project(scope, observations)
    elapsed = System.monotonic_time(:millisecond) - started
    :ok = :telemetry.detach(handler)

    batch_times = drain_batch_times([])
    longest = Enum.max(batch_times)

    # Repo.transaction/2 elapsed time includes checkout wait, so it is an
    # upper bound on how long a pooled connection was held. Sandbox owns its
    # connection for the whole test and cannot expose a physical checkout span.
    IO.puts(
      "RECONCILE_BENCH total_ms=#{elapsed} upserted=#{result.upserted} " <>
        "batches=#{length(batch_times)} longest_transaction_ms=#{longest} " <>
        "peak_pool_checkout_upper_bound_ms=#{longest}"
    )

    assert result.upserted == 5_000
    assert length(batch_times) == 20
  end

  defp drain_batch_times(acc) do
    receive do
      {:batch_ms, ms} -> drain_batch_times([ms | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
