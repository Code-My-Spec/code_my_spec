defmodule CmsHarness.Agents.Engine.ImplTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.State

  defp state, do: %{turn: nil, queue: []}
  defp entry(ref), do: %{ref: ref, message: ref, timeout: 1_000}

  test "an idle agent starts offered work immediately" do
    assert {:start, %{ref: "first"}, state} = State.offer(state(), entry("first"))
    assert state == %{turn: nil, queue: []}
  end

  test "a busy agent queues work in arrival order and starts it when idle" do
    busy = %{turn: %{task: :running}, queue: []}
    assert {:queued, queued} = State.offer(busy, entry("second"))
    assert %{busy?: true, queued: 1} = State.status(queued)
    assert {:start, %{ref: "second"}, %{turn: nil, queue: []}} = State.finish(queued)
  end

  test "only queued work can be withdrawn" do
    busy = %{turn: %{task: :running}, queue: [entry("second")]}
    assert {:ok, %{queue: []}} = State.withdraw(busy, "second")
    assert :already_delivered = State.withdraw(busy, "first")
  end
end
