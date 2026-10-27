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

  defp timing(outcome, gate_seconds, landing_seconds) do
    stages = Map.new(Timings.stages(), &{&1, %{status: :not_run, duration_seconds: nil}})
    stages = Map.put(stages, "gate-build", %{status: :ran, duration_seconds: gate_seconds})

    stages =
      if landing_seconds == nil,
        do: stages,
        else: Map.put(stages, "landing", %{status: :ran, duration_seconds: landing_seconds})

    waits =
      Map.new(~w(compiler credo exunit spex), &{&1, %{status: :not_run, duration_seconds: nil}})

    %{outcome: outcome, stages: stages, analyzer_waits: waits, gate_seconds: gate_seconds}
  end
end
