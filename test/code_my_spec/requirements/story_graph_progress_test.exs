defmodule CodeMySpec.Requirements.StoryGraphProgressTest do
  @moduledoc """
  The cockpit's story pie counts the slice the working copy status page draws.

  It counted `requirements_nodes` rows for the story and its issues while the
  status page drew the story's components' requirements and project gates as
  well, so the two disagreed (2026-10-14). Both now read `story_graph/2`; this
  pins what the pie counts out of it.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.StoryGraph

  defp node(type, id, name, satisfied, details \\ %{}),
    do: %{entity_type: type, entity_id: id, name: name, satisfied: satisfied, details: details}

  test "counts the story's own, its issues' and its components' requirements, not gates or other stories" do
    nodes = [
      node("story", 7, "spex_written", true),
      node("story", 7, "qa_complete", false),
      node("issue", "i-1", "submitted", true, %{"story_id" => 7}),
      node("component", "c-1", "implementation_file", false),
      node("project", "p", "personas_complete", true),
      node("story", 8, "spex_written", true),
      node("component", "c-other", "implementation_file", true)
    ]

    edges = [%{from: {"project", "p", "personas_complete"}, to: {"story", 7, "spex_written"}}]
    graph = %{nodes: nodes, edges: edges, actionable: []}

    slice = StoryGraph.select(graph, 7, MapSet.new(["c-1"]))

    assert length(slice.nodes) == 5, "the gate is drawn as context beside the four the story owns"
    assert StoryGraph.progress(slice) == {2, 4}
  end
end
