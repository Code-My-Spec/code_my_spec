defmodule CmsHarness.Agents.Engine.ImplTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.State

  defp state, do: %{turn: nil, queue: []}
  defp entry(ref), do: %{ref: ref, message: ref, timeout: 1_000}

  test "an absent agent is not running, including before the registry starts" do
    assert {:error, :not_running} = State.whereis("absent-#{System.unique_integer([:positive])}")
  end

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

  test "work availability cannot queue beside an active turn" do
    busy = %{turn: %{ref: "chat"}, queue: []}
    assert {:rejected, :busy, ^busy} = State.offer_work(busy, entry("work"))
    assert {:idle, idle} = State.finish(busy)
    assert {:start, %{ref: "work"}, _} = State.offer_work(idle, entry("work"))
  end

  test "replayed work requests stay rejected after the turn ends" do
    assert {:start, _, admitted} = State.offer_work(state(), entry("work"))
    assert {:rejected, :duplicate, ^admitted} = State.offer_work(admitted, entry("work"))
    assert {:idle, idle} = State.finish(Map.put(admitted, :turn, %{ref: "work"}))
    assert {:rejected, :duplicate, ^idle} = State.offer_work(idle, entry("work"))
    assert {:start, _, _} = State.offer_work(idle, entry("later-work"))
  end

  test "work requests do not displace queued user messages" do
    queued = %{turn: nil, queue: [entry("user-message")]}
    assert {:rejected, :busy, ^queued} = State.offer_work(queued, entry("work"))
  end
end
