defmodule CodeMySpecWeb.TelemetryMemoryReportTest do
  use ExUnit.Case, async: true

  alias CodeMySpecWeb.Telemetry

  test "the memory line names each total and the largest processes and tables" do
    memory = %{total: 734_003_200, processes: 209_715_200, binary: 104_857_600, ets: 52_428_800}

    line =
      Telemetry.memory_report(memory, [{":embed_pool", 157_286_400}], [
        {":graph_cache", 31_457_280}
      ])

    assert line =~ "[Memory] total=700.0MB processes=200.0MB binary=100.0MB ets=50.0MB atom=0.0MB"
    assert line =~ "top_procs=:embed_pool:150.0MB"
    assert line =~ "top_ets=:graph_cache:30.0MB"
    assert line =~ ~r/procs=\d+/
  end

  test "reporting reads the live node without raising" do
    assert :ok = Telemetry.report_memory()
  end
end
