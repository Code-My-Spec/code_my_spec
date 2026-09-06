defmodule CmsHarness.Agents.Tools.StartTask do
  @moduledoc """
  The third of the spine, carried directly. See
  `CmsHarness.Agents.Tools.GetNextRequirement` for why all four are here.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "start_task",
    nothing_to: "no task it can start"

  @impl true
  def description do
    """
    Begin work on one requirement, and get the prompt for it.

    The prompt is the point: it carries the spec template, the design rules, the
    file paths and the test patterns for this particular component, and it is
    not the same for two requirements. Take what `get_next_requirement` returned
    and pass it here rather than working from what the requirement's name
    suggests.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        requirement_name: %{
          type: "string",
          description: "Name of the requirement, e.g. spec_file, implementation_file"
        },
        entity_type: %{
          type: "string",
          description: "component, story, or project"
        },
        entity_id: %{
          type: "string",
          description: "Id of the entity that owns this requirement"
        },
        module_name: %{
          type: "string",
          description:
            "Component module name, an alternative to entity_id for component requirements"
        },
        agent_id: %{
          type: "string",
          description: "Your agent id — claims ownership of the task"
        }
      },
      required: ["requirement_name", "entity_type"]
    }
  end
end
