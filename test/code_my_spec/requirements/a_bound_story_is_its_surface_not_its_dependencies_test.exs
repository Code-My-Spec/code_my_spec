defmodule CodeMySpec.Requirements.ABoundStoryIsItsSurfaceNotItsDependenciesTest do
  @moduledoc """
  d1a69b4e. An agent bound to a story is offered the story's own components: its
  surface and the surface's descendants. Not the components the surface depends
  on, nor their children — story 1083's surface reached `AgentTasks` through two
  dependencies, and its coder was handed 568 of 1,319 components, phantom
  modules of retired stories among them. The dependency closure still gates the
  story; it is not the team's work.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.StoryExecution

  # Architecture (surface) ─ child ArchitectureLive
  #   └ depends on Requirements ─ child AgentTasks ─ child ContextSpec
  defp graph do
    agent_tasks_child = component("CodeMySpec.AgentTasks.ContextSpec", parent: "agent_tasks")
    agent_tasks = component("CodeMySpec.AgentTasks", parent: "requirements", id: "agent_tasks")
    requirements = component("CodeMySpec.Requirements", id: "requirements")
    surface_child = component("CodeMySpec.Architecture.Live", parent: "architecture")

    surface =
      component("CodeMySpec.Architecture", id: "architecture", dependencies: [requirements])

    components = [surface, surface_child, requirements, agent_tasks, agent_tasks_child]

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
      parent_component_id: Keyword.get(opts, :parent),
      dependencies: Keyword.get(opts, :dependencies, [])
    }
  end

  defp file_node(id), do: %{entity_type: "component", entity_id: id, name: "implementation_file"}

  test "the bound set is the surface and its own descendants" do
    g = graph()

    assert RequirementGraph.story_surface_ids(g.story, g) ==
             MapSet.new([g.ids["CodeMySpec.Architecture"], g.ids["CodeMySpec.Architecture.Live"]])
  end

  test "a dependency's descendant is not the bound story's work" do
    g = graph()

    refute StoryExecution.story_work?(
             g.story,
             file_node(g.ids["CodeMySpec.AgentTasks.ContextSpec"]),
             g
           ),
           "a phantom AgentTasks module reached through Architecture's dependencies " <>
             "was counted as story 1083's work"

    refute StoryExecution.story_work?(g.story, file_node(g.ids["CodeMySpec.Requirements"]), g)

    assert StoryExecution.story_work?(
             g.story,
             file_node(g.ids["CodeMySpec.Architecture.Live"]),
             g
           )
  end

  test "the closure the story is gated on still reaches its dependencies" do
    g = graph()
    closure = RequirementGraph.story_component_ids(g.story, g)

    assert MapSet.member?(closure, g.ids["CodeMySpec.AgentTasks.ContextSpec"]),
           "kickoff gating lost the dependency closure; only the bound set should narrow"
  end
end
