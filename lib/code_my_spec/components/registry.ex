defmodule CodeMySpec.Components.Registry do
  @moduledoc """
  Central registry containing all component type-specific metadata and behavior definitions.
  Provides the authoritative source for component type characteristics including requirements,
  display properties, workflow rules, and validation logic.
  """

  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.RequirementDefinitionData

  @type type_definition :: %{
          requirements: [RequirementDefinition.t()],
          display_name: String.t(),
          description: String.t(),
          document_type: String.t(),
          icon: String.t() | nil,
          color: String.t() | nil
        }

  @type_definitions %{
    "genserver" => %{
      requirements: RequirementDefinitionData.default_requirements(),
      display_name: "GenServer",
      document_type: "spec",
      description: "Stateful process that handles requests and maintains state",
      icon: "cpu-chip",
      color: "green"
    },
    "context" => %{
      requirements: [
        RequirementDefinitionData.context_spec_file(),
        RequirementDefinitionData.context_spec_valid(),
        RequirementDefinitionData.children_designs(),
        RequirementDefinitionData.review_file(),
        RequirementDefinitionData.review_valid(),
        RequirementDefinitionData.children_implementations(),
        RequirementDefinitionData.dependencies_satisfied(),
        RequirementDefinitionData.implementation_file(),
        RequirementDefinitionData.test_file(),
        RequirementDefinitionData.test_spec_alignment(),
        RequirementDefinitionData.tests_passing()
      ],
      document_type: "context_spec",
      display_name: "Context",
      description: "Application domain boundary providing public API",
      icon: "squares-2x2",
      color: "purple"
    },
    "coordination_context" => %{
      requirements: [
        RequirementDefinitionData.context_spec_file(),
        RequirementDefinitionData.context_spec_valid(),
        RequirementDefinitionData.children_designs(),
        RequirementDefinitionData.review_file(),
        RequirementDefinitionData.review_valid(),
        RequirementDefinitionData.children_implementations(),
        RequirementDefinitionData.dependencies_satisfied(),
        RequirementDefinitionData.implementation_file(),
        RequirementDefinitionData.test_file(),
        RequirementDefinitionData.test_spec_alignment(),
        RequirementDefinitionData.tests_passing()
      ],
      document_type: "context_spec",
      display_name: "Coordination Context",
      description: "Context that coordinates between multiple domains",
      icon: "arrow-path",
      color: "orange"
    },
    "schema" => %{
      requirements: [
        RequirementDefinitionData.spec_file(),
        RequirementDefinitionData.schema_spec_valid(),
        RequirementDefinitionData.implementation_file()
      ],
      document_type: "schema",
      display_name: "Schema",
      description: "Data structure definition with validation rules",
      icon: "table-cells",
      color: "blue"
    },
    "repository" => %{
      requirements: RequirementDefinitionData.default_requirements(),
      document_type: "spec",
      display_name: "Repository",
      description: "Data access layer abstracting database operations",
      icon: "archive-box",
      color: "indigo"
    },
    "task" => %{
      requirements: RequirementDefinitionData.default_requirements(),
      document_type: "spec",
      display_name: "Task",
      description: "Background job or one-time operation",
      icon: "clock",
      color: "yellow"
    },
    "registry" => %{
      requirements: RequirementDefinitionData.default_requirements(),
      document_type: "spec",
      display_name: "Registry",
      description: "Process registry for dynamic process lookup",
      icon: "book-open",
      color: "teal"
    },
    "behaviour" => %{
      requirements: [
        RequirementDefinitionData.spec_file(),
        RequirementDefinitionData.spec_valid(),
        RequirementDefinitionData.implementation_file()
      ],
      document_type: "spec",
      display_name: "Behaviour",
      description: "Behaviour that defines callbacks for other modules",
      icon: "book-open",
      color: "teal"
    },
    "liveview" => %{
      requirements: [
        RequirementDefinitionData.liveview_spec_file(),
        RequirementDefinitionData.liveview_spec_valid(),
        RequirementDefinitionData.implementation_file(),
        RequirementDefinitionData.test_file(),
        RequirementDefinitionData.test_spec_alignment(),
        RequirementDefinitionData.tests_passing()
      ],
      document_type: "liveview",
      display_name: "LiveView",
      description: "Phoenix LiveView page with real-time UI interactions",
      icon: "window",
      color: "emerald"
    },
    "liveview_component" => %{
      requirements: [
        RequirementDefinitionData.liveview_spec_file(),
        RequirementDefinitionData.liveview_spec_valid(),
        RequirementDefinitionData.implementation_file(),
        RequirementDefinitionData.test_file(),
        RequirementDefinitionData.test_spec_alignment(),
        RequirementDefinitionData.tests_passing()
      ],
      document_type: "liveview",
      display_name: "LiveView Component",
      description: "Reusable Phoenix LiveView component",
      icon: "puzzle-piece",
      color: "teal"
    },
    "other" => %{
      requirements: RequirementDefinitionData.default_requirements(),
      display_name: "Other",
      document_type: "spec",
      description: "Custom component type",
      icon: "cube",
      color: "gray"
    }
  }

  @spec get_type(String.t()) :: type_definition()
  def get_type(component_type) do
    case Map.get(@type_definitions, component_type, nil) do
      nil ->
        # Return default requirements for components without a type
        %{
          requirements: RequirementDefinitionData.default_requirements(),
          display_name: "Unknown",
          description: "Component type not yet defined",
          document_type: "spec",
          icon: "question-mark-circle",
          color: "gray"
        }

      type_def ->
        type_def
    end
  end

  @spec get_requirements_for_type(String.t()) :: [RequirementDefinition.t()]
  def get_requirements_for_type(component_type) do
    get_type(component_type).requirements
  end
end
