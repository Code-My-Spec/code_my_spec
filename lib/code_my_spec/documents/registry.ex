defmodule CodeMySpec.Documents.Registry do
  @moduledoc """
  Central registry for document type definitions including section requirements,
  descriptions, and specifications used for AI-generated design documents.
  """

  @type document_definition :: %{
          overview: String.t(),
          required_sections: [String.t() | [String.t()]],
          optional_sections: [String.t()],
          allowed_additional_sections: [String.t()] | String.t(),
          section_descriptions: %{String.t() => String.t()}
        }

  @spec_type """
  Format:
  - Use H2 heading
  - Single line with the component type string

  Content:
  - Declares the component type for this module
  - Must be a lowercase string matching a known component type
  - Used by sync to set the component's type in the database

  Examples:
  - ## Type
    liveview
  - ## Type
    schema
  - ## Type
    genserver
  """

  @spec_components """
  Format:
  - Use H2 heading
  - Use H3 headers for each component module
  - Include description text

  Content:
  - Module names must be valid Elixir modules (PascalCase)
  - Include brief description
  - Focus on architectural relationships, not implementation details
  - Show clear separation of concerns
  - Indicate behavior contracts where applicable
  - Use consistent naming conventions
  - Component types are user-defined strings matching your architecture

  Examples:
  - ## Components
    ### ModuleName

    Brief description of the component's responsibility.
  """

  @spec_delegates """
  Format:
  - Use H2 heading
  - Simple bullet list of delegate function definitions

  Content:
  - Each item shows function/arity delegation in format: function_name/arity: Target.Module.function_name/arity
  - Only include functions that are delegated to other modules

  Examples:
  - ## Delegates
    - list_components/1: Components.ComponentRepository.list_components/1
    - get_component/2: Components.ComponentRepository.get_component/2
  """

  @spec_functions """
  Format:
  - Use H2 heading
  - Use H3 headers for each function in format: function_name/arity

  Content:
  - Document only PUBLIC functions (not private functions)
  - Each function should include:
    * Brief description of what the function does
    * Elixir @spec in code block
    * **Process**: Step-by-step description of the function's logic
    * **Test Assertions**: List of test cases for this function

  Examples:
  - ## Functions
    ### build/1
    Apply dependency tree processing to all components.
    ```elixir
    @spec build([Component.t()]) :: [Component.t()]
    ```
    **Process**:
    1. Topologically sort components to process dependencies first
    2. Reduce over sorted components, building a map of processed components
    **Test Assertions**:
    - returns empty list for empty input
    - processes components in dependency order
  """

  @spec_dependencies """
  Format:
  - Use H2 heading
  - Simple bullet list of module names

  Content:
  - Each item must be a valid Elixir module name (PascalCase)
  - No descriptions - just the module names
  - Only include modules this module depends on

  Examples:
  - ## Dependencies
    - CodeMySpec.Components
    - CodeMySpec.Utils
  """

  @spec_fields """
  Format:
  - Use H2 heading
  - Table format with columns: Field, Type, Required, Description, Constraints

  Content:
  - Only applicable for schemas and structs
  - List all schema fields with their Ecto types
  - Mark required fields clearly (Yes/No or Yes (auto) for auto-generated)
  - Include constraints (length, format, references)

  Examples:
  - ## Fields
    | Field       | Type         | Required   | Description           | Constraints         |
    | ----------- | ------------ | ---------- | --------------------- | ------------------- |
    | id          | integer      | Yes (auto) | Primary key           | Auto-generated      |
    | name        | string       | Yes        | Name field            | Min: 1, Max: 255    |
    | foreign_id  | integer      | Yes        | Foreign key           | References table.id |
  """

  @review_overview """
  Format:
  - Use H2 heading
  - Brief paragraph (2-4 sentences)

  Content:
  - State what was reviewed (context name and component count)
  - Summarize the overall assessment (sound/needs work)
  """

  @review_architecture """
  Format:
  - Use H2 heading
  - Bullet list of findings

  Content:
  - Assess separation of concerns
  - Validate component type usage (schema, repository, service patterns)
  - Check dependency relationships
  - Flag any architectural concerns
  """

  @review_integration """
  Format:
  - Use H2 heading
  - Bullet list of integration points

  Content:
  - List how components connect
  - Identify public APIs and delegation points
  - Note any missing or problematic integration points
  """

  @review_stories """
  Format:
  - Use H2 heading
  - Bullet list mapping stories to components

  Content:
  - For each user story, confirm which components satisfy it
  - Identify any gaps in coverage
  """

  @review_issues """
  Format:
  - Use H2 heading
  - Bullet list or "None found"

  Content:
  - List any issues discovered during review
  - For each issue, note if it was fixed and how
  """

  @review_conclusion """
  Format:
  - Use H2 heading
  - Single paragraph

  Content:
  - State readiness for implementation (ready/blocked)
  - List any remaining action items if blocked
  """

  @spec_route """
  Format:
  - Use H2 heading
  - Single line with the URL path pattern in backticks

  Content:
  - Define the URL path pattern for this LiveView
  - Use colon-prefixed parameters for dynamic segments (e.g., `:id`, `:slug`)

  Examples:
  - ## Route
    `/accounts/:id/manage`
  """

  @spec_params """
  Format:
  - Use H2 heading
  - Bullet list of parameter names and types, or "None"

  Content:
  - Document URL parameters and their types
  - Only include path and query parameters relevant to this LiveView

  Examples:
  - ## Params
    - `id` - integer, account ID
  - ## Params
    None
  """

  @spec_liveview_components """
  Format:
  - Use H2 heading
  - Bullet list of child component module names, or "None"

  Content:
  - List LiveView components (function components, live components) used by this view
  - Include brief description of each component's role

  Examples:
  - ## Components
    - AccountLive.Components.Navigation - sidebar navigation with active tab
    - AccountLive.Components.SettingsForm - account settings form
  - ## Components
    None
  """

  @spec_user_interactions """
  Format:
  - Use H2 heading
  - Bold event names with descriptions

  Content:
  - Map each user action to its behavior and context calls
  - Use Phoenix event format (phx-change, phx-submit, phx-click)
  - Describe what happens and which context function is called

  Examples:
  - ## User Interactions
    - **phx-submit="save"**: Validate form params, call Accounts.update_account/2, flash success or show errors.
    - **phx-change="validate"**: Live-validate form inputs and update changeset in assigns.
  """

  @spec_design """
  Format:
  - Use H2 heading
  - Structured prose describing layout, components, and responsive behavior

  Content:
  - Describe the layout structure (sidebar, grid, single-column, etc.)
  - List DaisyUI component choices (e.g., .card, .btn-primary, .form-control)
  - Describe responsive behavior
  - This is a structural description, not renderable HTML

  Examples:
  - ## Design
    Layout: Centered single-column page
    Main content:
      - Card: Account settings form (name, description fields)
      - Card.danger: Delete account section (owners only, with confirmation)
    Components: .card, .form-control, .btn-primary, .btn-error
    Responsive: Stack cards vertically on mobile
  """

  @proposal_contexts """
  Format:
  - Use H2 heading: ## Contexts
  - Use H3 for each context module name (fully qualified, e.g., ### AppName.ContextName)
  - Include bullet list with **Type:**, **Description:**, **Stories:**
  - Use H4 "#### Children" subsection with bullet list of child components

  Content:
  - Each context represents a bounded domain (e.g., Accounts, Orders, Billing)
  - Module names must be fully qualified (e.g., MyApp.Accounts, not just Accounts)
  - Stories field lists story IDs that this context satisfies (for dual mapping)
  - Children are schemas/modules within the context

  Example:
  ## Contexts

  ### MyApp.Accounts

  - **Type:** context
  - **Description:** User account management and authentication
  - **Stories:** 1, 2, 5

  #### Children

  - MyApp.Accounts.User (schema) [Stories: 1, 2]: User account record
  - MyApp.Accounts.Session (schema) [Stories: 5]: Login session tracking
  """

  @proposal_surface_components """
  Format:
  - Use H2 heading: ## Surface Components
  - Use H3 for each component module name (fully qualified, e.g., ### AppNameWeb.PageLive)
  - Include bullet list with **Type:**, **Description:**, **Stories:**

  Content:
  - Surface components are LiveViews, Controllers, or Plugs (the UI layer)
  - Module names must start with AppNameWeb (e.g., MyAppWeb.DashboardLive)
  - Stories field lists story IDs that this surface handles (for dual mapping)
  - Type should be: liveview, controller, or module

  Example:
  ## Surface Components

  ### MyAppWeb.DashboardLive

  - **Type:** liveview
  - **Description:** Main dashboard showing account overview
  - **Stories:** 1, 2
  """

  @proposal_dependencies """
  Format:
  - Use H2 heading: ## Dependencies
  - Simple bullet list with arrow notation: From -> To

  Content:
  - Surface components depend on contexts (required)
  - Contexts may depend on other contexts (optional)
  - No circular dependencies allowed

  Example:
  ## Dependencies

  - MyAppWeb.DashboardLive -> MyApp.Accounts
  - MyAppWeb.DashboardLive -> MyApp.Reports
  - MyApp.Reports -> MyApp.Accounts
  """

  @default_spec_definition %{
    overview: """
    Spec documents provide comprehensive documentation for Elixir modules following a
    structured format. Each spec includes module metadata, public API documentation,
    delegation information, dependencies, and detailed function specifications.

    Specs are parsed using convention-based section parsers:
    - "functions" section → Documents.Parsers.FunctionParser (returns structured Function schemas)
    - "fields" section → Documents.Parsers.FieldParser (returns structured Field schemas)
    - Other sections → Plain text extraction

    Specs should focus on WHAT the module does, not HOW it does it. Keep them concise
    and human-readable, as they're consumed by both humans and AI agents.
    """,
    required_sections: [["delegates", "functions"], "dependencies"],
    optional_sections: ["fields"],
    allowed_additional_sections: [],
    section_descriptions: %{
      "type" => @spec_type,
      "delegates" => @spec_delegates,
      "functions" => @spec_functions,
      "dependencies" => @spec_dependencies,
      "fields" => @spec_fields
    }
  }

  @document_definitions %{
    "spec" => @default_spec_definition,
    "schema" => %{
      overview: """
      Schema components represent Ecto schema entities that define data structures,
      relationships, and validation rules for persistence in the database. Each schema
      documents its fields, associations, validations, and database constraints.
      """,
      required_sections: ["fields"],
      optional_sections: ["functions", "dependencies"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "type" => @spec_type,
        "functions" => @spec_functions,
        "dependencies" => @spec_dependencies,
        "fields" => @spec_fields
      }
    },
    "context_spec" => %{
      overview: """
      Spec documents provide comprehensive documentation for Elixir modules following a
      structured format. Each spec includes module metadata, public API documentation,
      delegation information, dependencies, detailed function specifications, and
      titles and brief descriptions of components contained by the context.

      Specs should focus on WHAT the module does, not HOW it does it. Keep them concise
      and human-readable, as they're consumed by both humans and AI agents.
      """,
      required_sections: [["delegates", "functions"], "dependencies", "components"],
      optional_sections: ["fields"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "type" => @spec_type,
        "delegates" => @spec_delegates,
        "functions" => @spec_functions,
        "dependencies" => @spec_dependencies,
        "fields" => @spec_fields,
        "components" => @spec_components
      }
    },
    "dynamic_document" => %{
      overview: "A fully dynamic document",
      required_sections: [],
      optional_sections: [],
      allowed_additional_sections: "*"
    },
    "design_review" => %{
      overview: """
      Design review documents summarize architectural analysis of a Phoenix context
      and its child components. Reviews validate consistency, integration, and
      alignment with user stories. Keep reviews concise and actionable.
      """,
      required_sections: ["overview", "architecture", "integration", "conclusion"],
      optional_sections: ["stories", "issues"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "overview" => @review_overview,
        "architecture" => @review_architecture,
        "integration" => @review_integration,
        "stories" => @review_stories,
        "issues" => @review_issues,
        "conclusion" => @review_conclusion
      }
    },
    "liveview" => %{
      overview: """
      LiveView spec documents define Phoenix LiveView pages including routing,
      user interactions, layout design, and dependencies. They follow a UI-focused
      format describing what the view does and how it looks, with detailed function
      specifications for mount, handle_event, and render callbacks.

      Specs should focus on WHAT the view does, not HOW it does it. Keep them concise
      and human-readable, as they're consumed by both humans and AI agents.
      """,
      required_sections: ["route", "user interactions", "dependencies"],
      optional_sections: ["params", "components", "design", "functions"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "type" => @spec_type,
        "route" => @spec_route,
        "params" => @spec_params,
        "components" => @spec_liveview_components,
        "user interactions" => @spec_user_interactions,
        "design" => @spec_design,
        "dependencies" => @spec_dependencies,
        "functions" => @spec_functions
      }
    },
    "architecture_proposal" => %{
      overview: """
      Architecture proposal documents define the component structure for a Phoenix application.
      They map user stories to both surface components (UI layer) and bounded contexts (domain layer).
      Each story must be mapped to BOTH a surface component AND a context/child (dual mapping).
      """,
      required_sections: ["contexts", "surface components", "dependencies"],
      optional_sections: [],
      allowed_additional_sections: [],
      section_descriptions: %{
        "contexts" => @proposal_contexts,
        "surface components" => @proposal_surface_components,
        "dependencies" => @proposal_dependencies
      }
    }
  }

  @spec get_definition(String.t()) :: document_definition()
  def get_definition(component_type) when is_binary(component_type) do
    Map.get(@document_definitions, component_type, @default_spec_definition)
  end
end
