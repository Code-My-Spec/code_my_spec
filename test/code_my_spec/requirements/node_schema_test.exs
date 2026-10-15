defmodule CodeMySpec.Requirements.NodeSchemaTest do
  @moduledoc """
  The changesets that keep a requirement row's identity and an edge honest.

  Three entity types, three partial unique indexes, one owner each — and an edge
  that joins two different nodes.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.{Edge, Node}

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "the changeset guards identity" do
    test "a node with no owner is refused" do
      changeset = Node.changeset(%Node{}, %{name: "orphan", description: "no owner"})

      refute changeset.valid?
    end

    test "a node with two owners is refused", %{scope: scope} do
      changeset =
        Node.changeset(%Node{}, %{
          name: "ambiguous",
          description: "two owners",
          project_id: scope.active_project_id,
          story_id: 1
        })

      refute changeset.valid?,
             "two owners satisfies two partial indexes, so the same node is reachable " <>
               "as two different nodes"
    end
  end

  test "a self-edge is refused by the changeset" do
    changeset = Edge.changeset(%Edge{}, %{from_requirement_id: 1, to_requirement_id: 1})

    refute changeset.valid?,
           "a self-edge is a one-node cycle — the node would never become actionable"
  end
end
