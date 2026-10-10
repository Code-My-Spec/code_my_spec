defmodule CodeMySpec.Requirements.VerificationTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.Verification

  @clean %{missing: 0, extra: 0, disagree: 0, edges_missing: 0, edges_extra: 0}

  test "equivalent JSON details and different freshness stamps describe the same behavior" do
    computed = requirement(%{problems: [%{source: :credo}], waiting_on: nil})

    stored = %{
      computed
      | details: %{"problems" => [%{"source" => "credo"}], "waiting_on" => nil},
        checked_at: ~N[2026-10-10 00:00:00],
        prerequisites: [12]
    }

    assert Verification.behavior(computed) == Verification.behavior(stored)
    assert Verification.clean?(@clean)
  end

  test "extra nodes fail agreement even with equal verdicts and edges" do
    refute Verification.clean?(%{@clean | extra: 1})
  end

  test "different offered work fails agreement" do
    refute Verification.clean?(Map.put(@clean, :actionable_disagree, 1))
  end

  test "waiting and execution changes are behavior changes" do
    ready = requirement(%{})
    waiting = %{ready | details: %{"waiting_on" => "answer"}}
    delegated = %{ready | execution_type: :sub_agent}

    assert Verification.changed_fields(
             Verification.behavior(ready),
             Verification.behavior(waiting)
           ) == [:details]

    assert Verification.changed_fields(
             Verification.behavior(ready),
             Verification.behavior(delegated)
           ) == [:execution_type]
  end

  test "stored definition selection participates in agreement" do
    first = %{
      satisfied: false,
      details: %{},
      owner_component_type: "context",
      node_scope: "child"
    }

    second = %{first | node_scope: "self"}

    assert Verification.changed_fields(Verification.stored(first), Verification.stored(second)) ==
             [:node_scope]
  end

  defp requirement(details),
    do: %Requirement{
      entity_type: "story",
      entity_id: 1,
      name: "qa_complete",
      satisfied: false,
      details: details
    }
end
