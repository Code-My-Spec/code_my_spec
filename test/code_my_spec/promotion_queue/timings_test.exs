defmodule CodeMySpec.PromotionQueue.TimingsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.PromotionQueue.Timings

  test "only the gate's full, named run contributes analyzer time" do
    began = ~U[2026-10-27 12:00:00Z]
    finished = ~U[2026-10-27 12:01:00Z]

    entry = %Entry{
      id: Ecto.UUID.generate(),
      status: :landed,
      result: %{
        "timing" => %{
          "gate_copy_id" => "gate",
          "run_ids" => [1, 2, 3],
          "stages" => %{"queue-wait" => 10, "gate-build" => 20, "compiler" => 999, "landing" => 0}
        }
      }
    }

    runs = [
      %Run{
        id: 1,
        source: "compiler",
        kind: :full,
        working_copy_id: "gate",
        started_at: DateTime.add(began, -30, :second),
        began_at: began,
        finished_at: finished
      },
      %Run{
        id: 2,
        source: "exunit",
        kind: :partial,
        working_copy_id: "gate",
        began_at: began,
        finished_at: DateTime.add(finished, 900)
      },
      %Run{
        id: 3,
        source: "credo",
        kind: :full,
        working_copy_id: "agent",
        began_at: began,
        finished_at: DateTime.add(finished, 900)
      }
    ]

    timing = Timings.build(entry, runs)
    assert timing.stages["compiler"] == %{status: :ran, duration_seconds: 60}
    assert timing.stages["exunit"] == %{status: :not_run, duration_seconds: nil}
    assert timing.stages["credo"] == %{status: :not_run, duration_seconds: nil}
    assert timing.stages["landing"] == %{status: :ran, duration_seconds: 0}
    assert timing.analyzer_waits["compiler"] == %{status: :ran, duration_seconds: 30}
    assert timing.analyzer_waits["exunit"] == %{status: :not_run, duration_seconds: nil}
    assert timing.total_seconds == 120
    assert timing.gate_seconds == 110
  end

  test "separates outcome statistics and excludes unreached stages" do
    landed = for seconds <- [60, 60, 120], do: timing(:landed, seconds, 0)
    ejected = for _ <- 1..8, do: timing(:ejected, 900, nil)
    summary = Timings.summarize(landed ++ ejected, "7d")

    assert summary["outcomes"]["landed"]["stages"]["gate-build"] == %{
             "count" => 3,
             "median_seconds" => 60,
             "p90_seconds" => 120,
             "total_seconds" => 240
           }

    assert summary["outcomes"]["ejected"]["gate_seconds"] == 7200
    refute Map.has_key?(summary["outcomes"]["ejected"]["stages"], "landing")
  end

  test "ranks only associated full gate run tests and files by duration" do
    entry = %Entry{
      id: Ecto.UUID.generate(),
      status: :landed,
      result: %{"timing" => %{"gate_copy_id" => "gate", "run_ids" => [1, 2, 3]}}
    }

    runs = [
      %Run{
        id: 1,
        source: "exunit",
        kind: :full,
        working_copy_id: "gate",
        stats: %{
          "timings" => %{
            "tests" => [
              %{
                "name" => "slow test",
                "file" => "test/sync_test.exs",
                "duration_us" => 39_000_000
              },
              %{"name" => "fast test", "file" => "test/sync_test.exs", "duration_us" => 2_000_000}
            ],
            "files" => [%{"file" => "test/sync_test.exs", "duration_us" => 41_000_000}]
          }
        }
      },
      %Run{
        id: 2,
        source: "spex",
        kind: :full,
        working_copy_id: "gate",
        stats: %{
          "timings" => %{
            "tests" => [
              %{
                "name" => "slow spex",
                "file" => "test/spex/slow_spex.exs",
                "duration_us" => 12_000_000
              }
            ],
            "files" => []
          }
        }
      },
      %Run{
        id: 3,
        source: "exunit",
        kind: :partial,
        working_copy_id: "gate",
        stats: %{
          "timings" => %{"tests" => [%{"name" => "unrelated", "duration_us" => 99_000_000}]}
        }
      }
    ]

    summary = entry |> Timings.build(runs) |> then(&Timings.summarize([&1]))

    assert [
             %{"name" => "slow test", "duration_seconds" => 39.0},
             %{"name" => "fast test", "duration_seconds" => 2.0}
           ] = summary["slowest_tests"]["exunit"]

    assert [%{"name" => "slow spex"}] = summary["slowest_tests"]["spex"]

    assert [%{"file" => "test/sync_test.exs", "duration_seconds" => 41.0}] =
             summary["slowest_files"]["exunit"]
  end

  defp timing(outcome, gate_seconds, landing_seconds) do
    stages = Map.new(Timings.stages(), &{&1, %{status: :not_run, duration_seconds: nil}})
    stages = Map.put(stages, "gate-build", %{status: :ran, duration_seconds: gate_seconds})

    stages = put_landing_stage(stages, landing_seconds)

    waits =
      Map.new(~w(compiler credo exunit spex), &{&1, %{status: :not_run, duration_seconds: nil}})

    %{outcome: outcome, stages: stages, analyzer_waits: waits, gate_seconds: gate_seconds}
  end

  defp put_landing_stage(stages, nil), do: stages

  defp put_landing_stage(stages, seconds) do
    Map.put(stages, "landing", %{status: :ran, duration_seconds: seconds})
  end
end
