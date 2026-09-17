defmodule CodeMySpec.Requirements.EveryDeclaredEventIsAppliedOrCountedTest do
  @moduledoc """
  The graph's vocabulary, checked against what it can actually apply.

  Story 1020, "A new way to move the graph cannot be added without saying how
  the graph applies it". Three things make that true and this is the third:
  `GraphInputs.event/6` refuses an undeclared kind, its `vantage` argument has
  no default so a writer must say whose answers it moves, and this asks whether
  every declared kind is either handled or written down as falling back.

  A kind that falls back is not a bug — handlers arrive one at a time and the
  projection is correct in the meantime, only slower. What is a bug is a kind
  that falls back and nobody knows: a recompute of everything it named, on
  every occurrence, indistinguishable from the batched pass this path replaced.
  So the debt is a list here rather than a silence.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.Handlers

  # Declared kinds with no handler, and why each one is still waiting.
  #
  # Handlers settle rows; they never create or remove them. So an event that
  # decides whether an entity projects *at all* cannot be handled without
  # teaching a handler to write rows, and falls back on purpose.
  @falls_back %{
    "story_created" => "a row that does not exist yet cannot be settled",
    "story_deleted" => "the rows go with the entity, which is `delete_departed`",
    "story_readiness_changed" => "`ready_for_dev` decides whether a story projects at all",
    "issue_changed" => "the catch-all kind; the five specific ones are handled",
    "component_created" => "a row that does not exist yet cannot be settled",
    "component_deleted" => "the rows go with the entity",
    "component_changed" => "moves the component set, which moves topology"
  }

  test "every declared event kind is either handled or recorded as falling back" do
    unaccounted =
      GraphInputs.kinds()
      |> Enum.reject(&(&1 in Handlers.handled_kinds() or Map.has_key?(@falls_back, &1)))

    assert unaccounted == [],
           """
           These event kinds are declared and nothing says what the graph does with them:

           #{Enum.map_join(unaccounted, "\n", &"  * #{&1}")}

           Give each a handler in `Handlers`, or add it to `@falls_back` here with the
           reason it cannot be settled. Falling back is a decision; being absent is not.
           """
  end

  test "nothing is listed as falling back that is actually handled" do
    stale = Enum.filter(Map.keys(@falls_back), &(&1 in Handlers.handled_kinds()))

    assert stale == [],
           "handled now, so remove from @falls_back: #{Enum.join(stale, ", ")}"
  end

  test "nothing is handled or listed that is not declared" do
    declared = GraphInputs.kinds()
    undeclared = Enum.reject(Handlers.handled_kinds() ++ Map.keys(@falls_back), &(&1 in declared))

    assert undeclared == [],
           "not in GraphInputs.kinds/0: #{Enum.join(Enum.uniq(undeclared), ", ")}"
  end

  test "an undeclared kind is refused rather than recorded" do
    assert_raise ArgumentError, ~r/not a declared graph event/, fn ->
      GraphInputs.event(Ecto.UUID.generate(), "Test", "invented_kind", %{}, [], :project_wide)
    end
  end
end
