defmodule CmsHarness.Agents.Engine.ImplTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine.State

  defp state, do: %{turn: nil}
  defp entry(ref), do: %{ref: ref, message: ref, timeout: 1_000}

  test "an absent agent is not running, including before the registry starts" do
    assert {:error, :not_running} =
             CmsHarness.Agents.whereis("absent-#{System.unique_integer([:positive])}")
  end

  test "work availability cannot queue beside an active turn" do
    busy = %{turn: %{ref: "chat"}}
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

  test "idle work requests hold no payload queue" do
    assert {:start, _, state} = State.offer_work(%{turn: nil}, entry("work"))
    refute Map.has_key?(state, :queue)
  end
end
