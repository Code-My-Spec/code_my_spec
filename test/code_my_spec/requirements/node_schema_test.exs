defmodule CodeMySpec.Requirements.NodeSchemaTest do
  @moduledoc """
  The changeset that keeps a requirement row's identity honest.

  Three entity types, three partial unique indexes, one owner each.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.Node

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
end
