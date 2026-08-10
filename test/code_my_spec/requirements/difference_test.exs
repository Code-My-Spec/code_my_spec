defmodule CodeMySpec.Requirements.DifferenceTest do
  @moduledoc """
  The message that decides whether the payload can be retired.

  It replaced one that said `nodes 13 vs 13, edges 12 vs 12` — a disagreement
  reported as two identical numbers, because the check was exact structural
  equality and the message could only talk about counts. Nobody can act on that,
  and a warning nobody acts on is one they learn to scroll past.

  So the tests split in two: the differences that are not differences must be
  silent, and the ones that are must name themselves precisely enough to fix
  without opening a console.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.{Difference, Requirement}

  defp req(name, opts \\ []) do
    %Requirement{
      entity_type: "component",
      entity_id: Keyword.get(opts, :entity_id, 1),
      name: name,
      description: name,
      satisfied: Keyword.get(opts, :satisfied, true),
      details: Keyword.get(opts, :details, %{})
    }
  end

  defp edge(from, to), do: %{from: {"component", 1, from}, to: {"component", 1, to}}

  describe "agreement" do
    test "identical graphs are silent" do
      nodes = [req("spec_file"), req("test_file")]
      edges = [edge("spec_file", "test_file")]

      assert Difference.describe(nodes, edges, nodes, edges) == :none
    end

    # Rows come back ordered by id, the computed graph in computation order.
    # A list comparison called that a difference on every single read.
    test "the same nodes in a different order are the same nodes" do
      a = req("spec_file")
      b = req("test_file")

      assert Difference.describe([b, a], [], [a, b], []) == :none
    end

    test "the same edges in a different order are the same edges" do
      one = edge("spec_file", "test_file")
      two = edge("test_file", "implementation_file")

      assert Difference.describe([], [two, one], [], [one, two]) == :none
    end

    # The write defaults nil details to `%{}`. A round trip returning the
    # default where the computation had nothing is the write working.
    test "a stored default against a computed nil is not a difference" do
      assert Difference.describe(
               [req("spec_file", details: %{})],
               [],
               [req("spec_file", details: nil)],
               []
             ) == :none
    end

    test "an empty graph on both sides is silent" do
      assert Difference.describe([], [], [], []) == :none
    end
  end

  describe "disagreement" do
    # The bug this whole comparison exists to catch: rows for requirements the
    # graph no longer produces. 798 `spec_file` rows outlived the config that
    # required them, and every one was served to an agent as work to do.
    test "a node only in the projection is named" do
      message =
        Difference.describe(
          [req("spec_file"), req("test_file")],
          [],
          [req("spec_file")],
          []
        )

      assert message =~ "1 node only in the projection"
      assert message =~ "test_file on component 1"
      refute message =~ "only in the payload"
    end

    test "a node only in the payload is named" do
      message = Difference.describe([req("spec_file")], [], [req("spec_file"), req("x")], [])

      assert message =~ "1 node only in the payload"
      assert message =~ "x on component 1"
    end

    # The verdict is the field an agent acts on, so a disagreement about it is
    # the one that changes what gets built.
    test "a disagreement about satisfied names the requirement and both values" do
      message =
        Difference.describe(
          [req("spec_file", satisfied: true)],
          [],
          [req("spec_file", satisfied: false)],
          []
        )

      assert message =~ "spec_file on component 1"
      assert message =~ "satisfied"
      assert message =~ "true"
      assert message =~ "false"
    end

    test "a differing edge is reported as an edge, not a node" do
      message =
        Difference.describe([], [edge("a", "b")], [], [edge("a", "c")])

      assert message =~ "edge only in the projection"
      assert message =~ "edge only in the payload"
      refute message =~ "node"
    end

    test "nodes and edges both differing are reported together" do
      message =
        Difference.describe([req("a")], [edge("a", "b")], [req("b")], [])

      assert message =~ "node"
      assert message =~ "edge"
      assert message =~ ";"
    end

    # A 1,426-node divergence must not print 1,426 keys into the log.
    test "a large divergence is summarized rather than dumped" do
      many = Enum.map(1..50, &req("req_#{&1}"))

      message = Difference.describe(many, [], [], [])

      assert message =~ "50 nodes only in the projection"
      assert message =~ "…"
      assert String.length(message) < 400
    end

    # Two callers compare these graphs: one picks what to serve, the other
    # checks that a write reads back. A verdict baked into the sentence is a lie
    # to whichever caller is not serving.
    test "the description carries no verdict about which side wins" do
      message = Difference.describe([req("a")], [], [], [])

      refute message =~ "serving"
    end
  end

  describe "normalize_details/1" do
    test "atom keys become strings" do
      assert Requirement.normalize_details(%{reason: "missing"}) == %{"reason" => "missing"}
    end

    test "string keys are left alone" do
      assert Requirement.normalize_details(%{"reason" => "missing"}) == %{"reason" => "missing"}
    end

    test "nil becomes an empty map" do
      assert Requirement.normalize_details(nil) == %{}
    end

    # Nested values are payloads, not schema. An `errors` map keyed by file path
    # would have its paths rewritten if this recursed.
    test "nested values are left as they are" do
      details = %{reason: "failed", errors: %{"lib/a.ex" => ["boom"]}}

      assert Requirement.normalize_details(details) == %{
               "reason" => "failed",
               "errors" => %{"lib/a.ex" => ["boom"]}
             }
    end

    test "normalizing twice changes nothing" do
      once = Requirement.normalize_details(%{reason: "missing"})

      assert Requirement.normalize_details(once) == once
    end
  end
end
