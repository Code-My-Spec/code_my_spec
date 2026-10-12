defmodule CodeMySpecWeb.WorkingCopyLive.StoryGraphLayoutTest do
  use ExUnit.Case, async: true

  alias CodeMySpecWeb.WorkingCopyLive.StoryGraphLayout
  alias LiveFlow.{Edge, Node, State}

  test "components share dependency-depth columns, independent of story branches" do
    flow =
      flow(
        ["leaf", "other_leaf", "middle", "users"],
        ["bdd", "triaged", "resolved", "ready", "qa"],
        [
          {"leaf", "middle"},
          {"middle", "users"},
          {"other_leaf", "users"},
          {"bdd", "leaf"},
          {"bdd", "other_leaf"},
          {"users", "ready"},
          {"triaged", "resolved"},
          {"resolved", "ready"},
          {"ready", "qa"}
        ]
      )

    arranged = StoryGraphLayout.arrange(flow)
    x = fn id -> arranged.nodes[id].position.x end

    assert x.("leaf") == x.("other_leaf")
    assert x.("middle") - x.("leaf") == x.("users") - x.("middle")
    assert x.("bdd") < x.("leaf")
    assert x.("triaged") < x.("resolved")
    assert x.("users") < x.("ready")
    assert x.("resolved") < x.("ready")
    assert x.("ready") < x.("qa")
    assert arranged.edges == flow.edges
    assert arranged == StoryGraphLayout.arrange(arranged)
  end

  test "cycle members share a column with enough space for measured cards" do
    flow = flow(["a", "b", "c"], [], [{"a", "b"}, {"b", "a"}, {"b", "c"}])
    flow = put_in(flow.nodes["a"].height, 250)
    arranged = StoryGraphLayout.arrange(flow)

    assert arranged.nodes["a"].position.x == arranged.nodes["b"].position.x
    assert arranged.nodes["b"].position.y >= arranged.nodes["a"].position.y + 250
    assert arranged.nodes["c"].position.x > arranged.nodes["b"].position.x
  end

  test "empty and story-only graphs are supported" do
    assert StoryGraphLayout.arrange(State.new()).nodes == %{}
    arranged = flow([], ["a", "b"], [{"a", "b"}]) |> StoryGraphLayout.arrange()
    assert arranged.nodes["a"].position.x < arranged.nodes["b"].position.x
  end

  defp flow(components, stories, edges) do
    nodes =
      for {id, type} <-
            Enum.map(components, &{&1, :context}) ++ Enum.map(stories, &{&1, :requirement}) do
        Node.new(id, %{x: 0, y: 0}, %{label: id}, type: type)
        |> Map.merge(%{width: 260, height: 112})
      end

    edges = for {from, to} <- edges, do: Edge.new("#{from}-#{to}", from, to)
    State.new(nodes: nodes, edges: edges)
  end
end
