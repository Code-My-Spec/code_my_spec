defmodule Mix.Tasks.Cms.GraphObservationsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  alias Mix.Tasks.Cms.GraphObservations

  setup do
    path =
      Path.join(System.tmp_dir!(), "graph-observations-#{System.unique_integer([:positive])}.log")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "a completed event observation passes even inside the grace window", %{path: path} do
    File.write!(path, """
    ts=2026-10-10T14:00:00 obs=abc [Files] announcing a graph change
    ts=2026-10-10T14:00:01 obs=abc [IncrementalGraph] accounted for 1 observation(s)
    """)

    output = capture_io(fn -> GraphObservations.run(["--logs", path]) end)
    assert output =~ "PASS"
    assert output =~ "consumed      1"
    assert output =~ "pending       0"
  end

  test "overlapping log files do not duplicate observations", %{path: path} do
    File.write!(path, """
    ts=2026-10-10T14:00:00 obs=abc [Files] announcing a graph change
    ts=2026-10-10T14:00:01 obs=abc [GraphWatcher] accounted for 1 observation(s)
    """)

    output = capture_io(fn -> GraphObservations.run(["--logs", path, "--logs", path]) end)
    assert output =~ "announced     1"
    assert output =~ "consumed      1"
  end

  test "the documented time-only filter excludes earlier announcements", %{path: path} do
    File.write!(path, """
    ts=2026-10-10T13:00:00 obs=old [Files] announcing a graph change
    ts=2026-10-10T14:00:00 obs=new [Files] announcing a graph change
    ts=2026-10-10T14:00:01 obs=new [GraphWatcher] accounted for 1 observation(s)
    """)

    output = capture_io(fn -> GraphObservations.run(["--logs", path, "--since", "14:00"]) end)
    assert output =~ "PASS"
    assert output =~ "announced     1"
  end

  test "an earlier completion cannot account for a later announcement", %{path: path} do
    File.write!(path, """
    ts=2026-10-10T14:00:00 obs=abc [GraphWatcher] accounted for 1 observation(s)
    ts=2026-10-10T14:00:01 obs=abc [Files] announcing a graph change
    ts=2026-10-10T14:01:00 heartbeat
    """)

    output =
      capture_io(fn ->
        assert catch_exit(GraphObservations.run(["--logs", path])) == {:shutdown, 1}
      end)

    assert output =~ "FAIL"
    assert output =~ "dropped       1"
  end

  test "a partial recompute is not evidence of a completed drain", %{path: path} do
    File.write!(path, """
    ts=2026-10-10T14:00:00 obs=abc [Files] announcing a graph change
    ts=2026-10-10T14:00:01 obs=abc [Requirements] recomputed
    ts=2026-10-10T14:01:00 heartbeat
    """)

    output =
      capture_io(fn ->
        assert catch_exit(GraphObservations.run(["--logs", path])) == {:shutdown, 1}
      end)

    assert output =~ "FAIL"
  end

  test "pending evidence cannot pass a gate", %{path: path} do
    File.write!(path, "ts=2026-10-10T14:00:00 obs=abc [Files] announcing a graph change\n")

    output =
      capture_io(fn ->
        assert catch_exit(GraphObservations.run(["--logs", path])) == {:shutdown, 1}
      end)

    assert output =~ "INCOMPLETE"
    refute output =~ "PASS"
  end

  test "empty evidence cannot pass a gate", %{path: path} do
    File.write!(path, "")

    output =
      capture_io(fn ->
        assert catch_exit(GraphObservations.run(["--logs", path])) == {:shutdown, 1}
      end)

    assert output =~ "No observations"
  end

  test "an unnamed announcement cannot silently disappear", %{path: path} do
    File.write!(path, "ts=2026-10-10T14:00:00 [Files] announcing a graph change\n")

    assert_raise Mix.Error, ~r/no observation ID/, fn ->
      GraphObservations.run(["--logs", path])
    end
  end

  test "missing logs fail instead of being silently ignored", %{path: path} do
    assert_raise File.Error, fn -> GraphObservations.run(["--logs", path]) end
  end

  test "unknown flags fail before reading evidence" do
    assert_raise Mix.Error, fn -> GraphObservations.run(["--sinc", "14:00"]) end
  end

  test "invalid time filters fail before reading evidence" do
    assert_raise Mix.Error, fn -> GraphObservations.run(["--since", "yesterday"]) end
  end
end
