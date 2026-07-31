defmodule CodeMySpec.Components.Registry do
  @moduledoc """
  What a component type *is*: display name, description, icon, colour, document
  type, dependency order.

  A plain table and two lookups over it. No database, no requirement
  definitions — everything that reads `RequirementDefinitionData` moved to
  `Requirements.Registry`, which is where the entry point for those was always
  meant to be.

  The split matters because this table is needed by both halves of the system.
  The light harness classifies files with it and holds no database; the server
  builds requirement graphs and does. Keeping the requirements lookups here
  would have meant a library calling back into the application that consumes
  it — which resolves fine while they are compiled together and fails at
  runtime the first time anyone uses the library on its own.
  """

  @type type_definition :: %{
          graph: atom(),
          display_name: String.t(),
          description: String.t(),
          document_type: String.t(),
          icon: String.t() | nil,
          color: String.t() | nil,
          dependency_order: non_neg_integer()
        }

  # `dependency_order` is the default sibling stack order when no
  # explicit cross-component dependency dictates one. Lower values
  # render first (closer to data), higher values render later
  # (closer to the user). Types without an explicit value default
  # to `@default_dependency_order` (rendered after the primitives).
  @default_dependency_order 5

  @type_definitions %{
    "genserver" => %{
      graph: :default_graph,
      display_name: "GenServer",
      document_type: "spec",
      description: "Stateful process that handles requests and maintains state",
      icon: "cpu-chip",
      color: "green"
    },
    "context" => %{
      graph: :context_graph,
      document_type: "context_spec",
      display_name: "Context",
      description: "Application domain boundary providing public API",
      icon: "squares-2x2",
      color: "purple"
    },
    "coordination_context" => %{
      graph: :context_graph,
      document_type: "context_spec",
      display_name: "Coordination Context",
      description: "Context that coordinates between multiple domains",
      icon: "arrow-path",
      color: "orange"
    },
    "schema" => %{
      graph: :schema_graph,
      document_type: "schema",
      display_name: "Schema",
      description: "Data structure definition with validation rules",
      icon: "table-cells",
      color: "blue",
      dependency_order: 0
    },
    "repository" => %{
      graph: :default_graph,
      document_type: "spec",
      display_name: "Repository",
      description: "Data access layer abstracting database operations",
      icon: "archive-box",
      color: "indigo",
      dependency_order: 2
    },
    "service" => %{
      graph: :default_graph,
      document_type: "spec",
      display_name: "Service",
      description: "Stateless service grouping related operations",
      icon: "wrench-screwdriver",
      color: "cyan",
      dependency_order: 3
    },
    "task" => %{
      graph: :default_graph,
      document_type: "spec",
      display_name: "Task",
      description: "Background job or one-time operation",
      icon: "clock",
      color: "yellow"
    },
    "registry" => %{
      graph: :default_graph,
      document_type: "spec",
      display_name: "Registry",
      description: "Process registry for dynamic process lookup",
      icon: "book-open",
      color: "teal"
    },
    "behaviour" => %{
      graph: :behaviour_graph,
      document_type: "spec",
      display_name: "Behaviour",
      description: "Behaviour that defines callbacks for other modules",
      icon: "book-open",
      color: "teal",
      dependency_order: 1
    },
    "controller" => %{
      graph: :default_graph,
      document_type: "spec",
      display_name: "Controller",
      description: "Phoenix controller handling HTTP requests and JSON responses",
      icon: "globe-alt",
      color: "cyan"
    },
    "json" => %{
      graph: :json_graph,
      document_type: "json",
      display_name: "JSON View",
      description: "Phoenix JSON view rendering structured responses for a controller",
      icon: "code-bracket",
      color: "cyan",
      dependency_order: 4
    },
    "live_context" => %{
      graph: :live_context_graph,
      document_type: "live_context_spec",
      display_name: "Live Context",
      description: "UI grouping of related LiveViews and LiveComponents under a shared namespace",
      icon: "rectangle-group",
      color: "emerald"
    },
    "liveview" => %{
      graph: :liveview_graph,
      document_type: "liveview",
      display_name: "LiveView",
      description: "Phoenix LiveView page with real-time UI interactions",
      icon: "window",
      color: "emerald",
      dependency_order: 4
    },
    "liveview_component" => %{
      graph: :liveview_graph,
      document_type: "liveview_component",
      display_name: "LiveView Component",
      description: "Reusable Phoenix LiveView component",
      icon: "puzzle-piece",
      color: "teal",
      dependency_order: 4
    },
    "skill" => %{
      graph: :default_graph,
      display_name: "Skill",
      document_type: "skill",
      description: "Agent-task playbook — a runnable, evaluatable agent procedure",
      icon: "sparkles",
      color: "pink"
    },
    "other" => %{
      graph: :default_graph,
      display_name: "Other",
      document_type: "spec",
      description: "Custom component type",
      icon: "cube",
      color: "gray"
    }
  }

  @spec get_type(String.t()) :: map()
  def get_type(component_type) do
    case Map.get(@type_definitions, component_type, nil) do
      nil ->
        %{
          graph: :default_graph,
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

  @doc """
  Default sibling stack order for a component type. Used by the
  graph projector when no explicit cross-component dependency
  dictates ordering. Lower values render first (closer to data),
  higher values render later (closer to the user).

  Types without an explicit ordering fall back to a neutral default
  that places them after the primitives.
  """
  @spec dependency_order(String.t()) :: non_neg_integer()
  def dependency_order(component_type) do
    component_type
    |> get_type()
    |> Map.get(:dependency_order, @default_dependency_order)
  end
end
