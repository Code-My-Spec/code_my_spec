defmodule CodeMySpec.Requirements.AStorysSubgraphTakesADependencyContextsChildrenNotGrandchildrenTest do
  @moduledoc """
  d1a69b4e. A story's components are its surface, the surface's descendants,
  everything those depend on transitively, and the direct children of the
  dependencies that are contexts — a context is implemented through them. Not
  grandchildren, and not the children's own dependencies. One set serves
  kickoff gating, priority and the bound team (John: option B).
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.StoryExecution

  # Architecture (surface) ── child Architecture.Live ── depends on Stories
  #   └ depends on Requirements (context) ── child AgentTasks (context)
  #                                             └ child ContextSpec
  defp graph do
    stories = component("CodeMySpec.Stories", id: "stories")
    context_spec = component("CodeMySpec.AgentTasks.ContextSpec", parent: "agent_tasks")

    agent_tasks =
      component("CodeMySpec.AgentTasks",
        parent: "requirements",
        id: "agent_tasks",
        type: "context"
      )

    requirements = component("CodeMySpec.Requirements", id: "requirements", type: "context")

    live =
      component("CodeMySpec.Architecture.Live", parent: "architecture", dependencies: [stories])

    surface =
      component("CodeMySpec.Architecture", id: "architecture", dependencies: [requirements])

    components = [surface, live, requirements, agent_tasks, context_spec, stories]

    %{
      components: components,
      components_by_id: Map.new(components, &{&1.id, &1}),
      story: %{id: 1083, component_id: "architecture"},
      ids: Map.new(components, &{&1.module_name, &1.id})
    }
  end

  defp component(name, opts) do
    %Component{
      id: Keyword.get(opts, :id, name),
      module_name: name,
      type: Keyword.get(opts, :type, "module"),
      parent_component_id: Keyword.get(opts, :parent),
      dependencies: Keyword.get(opts, :dependencies, [])
    }
  end

  defp file_node(id), do: %{entity_type: "component", entity_id: id, name: "implementation_file"}

  test "the subgraph is the surface, its descendants, what they depend on, and those contexts' children" do
    g = graph()

    assert RequirementGraph.story_component_ids(g.story, g) ==
             MapSet.new([
               g.ids["CodeMySpec.Architecture"],
               g.ids["CodeMySpec.Architecture.Live"],
               g.ids["CodeMySpec.Requirements"],
               g.ids["CodeMySpec.AgentTasks"],
               g.ids["CodeMySpec.Stories"]
             ])
  end

  test "a dependency context's child is the story's work; its grandchild is not" do
    g = graph()

    assert StoryExecution.story_work?(g.story, file_node(g.ids["CodeMySpec.Requirements"]), g)

    refute StoryExecution.story_work?(
             g.story,
             file_node(g.ids["CodeMySpec.AgentTasks.ContextSpec"]),
             g
           ),
           "a grandchild of a dependency context was counted as the story's work"

    assert StoryExecution.story_work?(g.story, file_node(g.ids["CodeMySpec.AgentTasks"]), g)
  end
end
