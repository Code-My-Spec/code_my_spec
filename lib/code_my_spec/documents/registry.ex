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

  @design_system_theme """
  Format:
  - Use H2 heading: ## Theme
  - Name the DaisyUI theme or describe custom theme

  Content:
  - The `data-theme` attribute value used in the application layout
  - Any theme overrides defined in `tailwind.config.js`
  - Light/dark mode strategy (single theme, toggle, system preference)

  Example:
  ## Theme

  Uses the `corporate` DaisyUI theme with dark mode toggle.
  `data-theme="corporate"` on the root html element.
  """

  @design_system_colors """
  Format:
  - Use H2 heading: ## Colors
  - Bullet list of semantic color roles with usage guidance

  Content:
  - Map each semantic role to when it should be used
  - Roles: primary, secondary, accent, neutral, base, info, success, warning, error
  - Include actual color values or DaisyUI variable names if customized
  - Note any custom colors beyond the DaisyUI palette

  Example:
  ## Colors

  - **Primary** (`primary`) — main actions, active navigation, links
  - **Secondary** (`secondary`) — supporting actions, secondary buttons
  - **Accent** (`accent`) — badges, highlights, attention-grabbing elements
  - **Neutral** (`neutral`) — borders, muted text, dividers
  - **Base** (`base-100/200/300`) — page background, card backgrounds, surface layers
  """

  @design_system_typography """
  Format:
  - Use H2 heading: ## Typography
  - Describe heading hierarchy, body text, and font choices

  Content:
  - Heading sizes and weights (h1 through h4) and when to use each
  - Body text size, line height, color
  - Font family if overriding DaisyUI defaults
  - Monospace usage for code or data display

  Example:
  ## Typography

  - **h1** — page titles only, one per page (`text-2xl font-bold`)
  - **h2** — section headings (`text-xl font-semibold`)
  - **h3** — card titles, subsections (`text-lg font-medium`)
  - **Body** — default DaisyUI body text
  - **Monospace** — code snippets and technical identifiers
  """

  @design_system_layout """
  Format:
  - Use H2 heading: ## Layout
  - Describe the application's page structure and navigation

  Content:
  - Navigation pattern (sidebar, top nav, both)
  - Content area width and padding
  - Page header/title conventions
  - Common page templates (list page, detail page, form page, dashboard)
  - Responsive breakpoints and behavior

  Example:
  ## Layout

  - **Navigation**: Fixed sidebar with top header bar
  - **Content width**: `max-w-7xl mx-auto` for main content area
  - **Page header**: Always includes breadcrumb and page title
  - **List pages**: Table with search/filter bar above, pagination below
  - **Form pages**: Centered card with max-w-2xl
  """

  @design_system_tone """
  Format:
  - Use H2 heading: ## Tone
  - Brief paragraph describing visual personality

  Content:
  - Overall aesthetic (minimal, dense, playful, corporate, etc.)
  - Corner style (rounded vs sharp)
  - Spacing density (tight vs airy)
  - Shadow/elevation approach (flat vs layered)
  - Any brand personality notes

  Example:
  ## Tone

  Clean and professional. Rounded corners (`rounded-lg`), airy spacing,
  minimal shadows. Dense data tables but spacious forms. No decorative
  elements — every visual element should serve a functional purpose.
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
    "design_system" => %{
      overview: """
      Design system documents define the visual identity and component conventions for a
      Phoenix application. They establish the DaisyUI theme, color usage, typography,
      layout patterns, and UI component conventions that all LiveViews and components
      must follow for visual consistency.
      """,
      required_sections: ["theme", "colors", "typography", "layout", "tone"],
      optional_sections: [],
      allowed_additional_sections: [],
      section_descriptions: %{
        "theme" => @design_system_theme,
        "colors" => @design_system_colors,
        "typography" => @design_system_typography,
        "layout" => @design_system_layout,
        "tone" => @design_system_tone
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
