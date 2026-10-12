defmodule CodeMySpec.Requirements.StoryGraphTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.{Requirement, StoryGraph}

  test "starts at the UI, follows context dependencies, and does not expand dependency children again" do
    components = [
      component("registration", "liveview", "user_live", ["users"]),
      component("settings", "liveview", "user_live", ["file_edits"]),
      component("user_live", "live_context"),
      component("users", "context", nil, ["mail"]),
      component("user_token", "schema", "users", ["file_edits"]),
      component("mail", "context"),
      component("file_edits", "context")
    ]

    nodes =
      Enum.map(components, &requirement("component", &1.id)) ++
        [requirement("story", 1), requirement("story", 2)]

    graph = %{
      nodes: nodes,
      actionable: nodes,
      edges: [
        %{
          from: {"component", "file_edits", "implementation_file"},
          to: {"component", "registration", "implementation_file"}
        }
      ]
    }

    result = StoryGraph.project(%{id: 1, component_id: "registration"}, components, graph)

    assert result.root_component.id == "registration"
    assert result.component_ids == MapSet.new(~w(registration users user_token mail))
    assert Enum.map(result.owners, & &1.id) == ["user_live"]

    assert Enum.all?(
             result.nodes,
             &(&1.entity_id in [1, "registration", "users", "user_token", "mail"])
           )

    assert result.edges == []
    assert Enum.map(result.actionable, & &1.entity_id) == Enum.map(result.nodes, & &1.entity_id)
    assert Enum.any?(result.component_edges, &(&1.from == "users" and &1.to == "mail"))
    refute Enum.any?(result.component_edges, &(&1.to == "file_edits"))
  end

  test "preserves authored edges absent from code, and handles cycles without broadening via owners" do
    components = [
      component("ui", "liveview", nil, ["users"]),
      component("users", "context", nil, ["projects"]),
      component("projects", "context", nil, ["users"])
    ]

    result =
      StoryGraph.project(%{id: 1, component_id: "ui"}, components, %{
        nodes: [],
        edges: [],
        actionable: []
      })

    assert result.component_ids == MapSet.new(~w(ui users projects))

    assert %{from: "users", to: "projects", provenance: :authored, in_code: false} in result.component_edges
  end

  test "an unlinked story retains only its own requirements" do
    result =
      StoryGraph.project(%{id: 1, component_id: nil}, [], %{
        nodes: [requirement("story", 1), requirement("story", 2)],
        edges: [],
        actionable: []
      })

    assert result.root_component == nil
    assert result.component_ids == MapSet.new()
    assert Enum.map(result.nodes, & &1.entity_id) == [1]
  end

  defp component(id, type, parent \\ nil, dependencies \\ []) do
    %{
      id: id,
      type: type,
      parent_component_id: parent,
      module_name: id,
      provenance: :authored,
      dependencies: Enum.map(dependencies, &%{id: &1}),
      outgoing_dependencies:
        Enum.map(dependencies, &%{target_component_id: &1, provenance: :authored, in_code: false})
    }
  end

  defp requirement(type, id),
    do: %Requirement{
      entity_type: type,
      entity_id: id,
      name: "implementation_file",
      satisfied: false
    }
end
