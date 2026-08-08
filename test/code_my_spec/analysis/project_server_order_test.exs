defmodule CodeMySpec.Analysis.ProjectServerOrderTest do
  @moduledoc """
  The queue is serialized, so its order is a latency policy.

  Five consecutive stops were blocked with "analysis pending or stale" while the
  answer the hook needed — credo, which finishes in milliseconds — sat behind a
  spex run of three and a half minutes. Nothing was broken; the queue was FIFO
  across sources that differ by three orders of magnitude. A slow queue and a
  dead analyzer are indistinguishable from the agent's side, which is what made
  it cost five stops to notice.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.ProjectServer

  defp entry(source, tag), do: %{job: %{source: source}, tag: tag}

  defp tags(queue), do: queue |> ProjectServer.order() |> Enum.map(& &1.tag)

  test "a cheap source jumps ahead of an expensive one already queued" do
    queue = [entry("spex", :spex), entry("credo", :credo)]

    assert tags(queue) == [:credo, :spex],
           "credo answers in milliseconds; making it wait on spex is the whole bug"
  end

  test "the four sources come out cheapest-first regardless of arrival order" do
    queue = [
      entry("spex", :spex),
      entry("exunit", :exunit),
      entry("compiler", :compiler),
      entry("credo", :credo)
    ]

    assert tags(queue) == [:credo, :compiler, :exunit, :spex]
  end

  test "arrival order is kept within a source" do
    queue = [entry("exunit", :first), entry("exunit", :second), entry("exunit", :third)]

    assert tags(queue) == [:first, :second, :third],
           "reordering across sources must not turn into reordering within one — " <>
             "two runs of the same analyzer are ordered by their inputs"
  end

  test "an unknown source sorts last rather than crashing" do
    queue = [entry("something_new", :unknown), entry("spex", :spex)]

    assert tags(queue) == [:spex, :unknown],
           "a source added later must not jump the queue by being unranked"
  end
end
