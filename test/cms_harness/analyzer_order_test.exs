defmodule CmsHarness.AnalyzerOrderTest do
  @moduledoc """
  The cheap analyzers go first.

  One `running` slot means the four execute strictly in turn, and their
  runtimes differ by more than an order of magnitude — compiler ~9s and credo
  ~10s against exunit ~2m10s and spex ~2m35s. Enqueued in the order the server
  asks for them, the two an agent can act on immediately arrive last. Measured:
  credo started 3.5 minutes after it was requested, behind a spex sweep.

  The cost is not slowness, it is wrong feedback that looks authoritative. A
  credo finding already fixed and verified came back five stops running, each
  time correctly marked stale and each time saying a rerun would replace it —
  and each rerun queued behind spex, so the replacement never landed inside the
  session.

  Ordering rather than a second slot: two concurrent `mix` invocations contend
  for one `_build`, so parallelism would trade this for a worse failure.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer

  defp order(sources) do
    sources
    |> Enum.with_index()
    |> Enum.reduce([], fn {source, i}, queue ->
      AnalysisServer.enqueue(queue, %{run_id: i, source: source, args: []})
    end)
    |> Enum.map(& &1.source)
  end

  test "a sweep runs cheapest first, whatever order it was asked for" do
    assert order(["spex", "exunit", "credo", "compiler"]) ==
             ["compiler", "credo", "exunit", "spex"]
  end

  test "the two actionable sources come before the two slow ones" do
    [first, second | _] = order(["spex", "exunit", "compiler", "credo"])

    assert first in ["compiler", "credo"]
    assert second in ["compiler", "credo"]
  end

  test "two runs of one source keep their arrival order" do
    queue =
      [%{run_id: 1, source: "spex", args: []}, %{run_id: 2, source: "spex", args: []}]
      |> Enum.reduce([], &AnalysisServer.enqueue(&2, &1))

    assert Enum.map(queue, & &1.run_id) == [1, 2]
  end

  test "an unknown source sorts last rather than crashing" do
    assert List.last(order(["sobelow", "compiler"])) == "sobelow"
  end
end
