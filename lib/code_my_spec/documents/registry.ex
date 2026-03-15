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

  @spec_live_context_liveviews """
  Format:
  - Use H2 heading
  - Use H3 headers for each LiveView module
  - Include bullet list with route and description

  Content:
  - Lists routed LiveViews that belong to this live context
  - Each LiveView has a module name, route path, and brief description
  - Routes use colon-prefixed parameters for dynamic segments

  Examples:
  - ## LiveViews
    ### UserLive.Index

    - **Route:** `/users`
    - **Description:** Lists all users with search and pagination

    ### UserLive.Show

    - **Route:** `/users/:id`
    - **Description:** Displays a single user's profile and activity
  """

  @spec_live_context_components """
  Format:
  - Use H2 heading
  - Use H3 headers for each LiveComponent module
  - Include brief description

  Content:
  - Lists LiveComponents shared across views in this context
  - Each component has a module name and description
  - Components are stateful (use phx-target={@myself})

  Examples:
  - ## Components
    ### UserLive.FormComponent

    Form for creating and editing users. Handles validation and submission.

    ### UserLive.FilterComponent

    Reusable search and filter controls for user lists.
  """

  @spec_assigns """
  Format:
  - Use H2 heading
  - Table format with columns: Assign, Type, Required, Description

  Content:
  - Lists all assigns for this LiveComponent
  - Must include `:id` assign (required by LiveComponent)
  - Mark required assigns clearly

  Examples:
  - ## Assigns
    | Assign | Type | Required | Description |
    | ------ | ---- | -------- | ----------- |
    | id     | any  | Yes      | Component instance identifier |
    | user   | User.t() | Yes  | User struct to display |
    | on_save | fun/1 | No    | Callback when form is saved |
  """

  @spec_livecomponent_events """
  Format:
  - Use H2 heading
  - Bold event names with descriptions

  Content:
  - handle_event callbacks scoped to this component via phx-target={@myself}
  - Parent communication via send(self(), msg)
  - Describe what happens and which context function is called

  Examples:
  - ## Events
    - **phx-submit="save"**: Validate params, call Accounts.update_user/2, notify parent via send(self(), {:user_saved, user}).
    - **phx-change="validate"**: Live-validate form inputs and update changeset in assigns.
  """

  @qa_brief_tool """
  Format:
  - Use H2 heading
  - Single line: tool name (web, curl, or script path)

  Content:
  - Which tool to use for this story's testing
  - `web` for LiveView pages, `curl` or script path for controller/API routes
  """

  @qa_brief_auth """
  Format:
  - Use H2 heading
  - Exact commands or instructions the tester copies verbatim

  Content:
  - Login URL, credentials, headers — whatever the tool needs
  - Reference auth scripts from the QA plan if applicable
  - Tester should not need to figure out auth on their own
  """

  @qa_brief_seeds """
  Format:
  - Use H2 heading
  - Exact commands to run

  Content:
  - Seed script references (`mix run priv/repo/qa_seeds.exs`)
  - Any story-specific seed commands beyond the base seeds
  - Entity IDs or values the tester will need
  """

  @qa_brief_what_to_test """
  Format:
  - Use H2 heading
  - Bullet list of specific test scenarios

  Content:
  - Specific URLs to visit
  - Interactions to perform (click, fill form, submit)
  - Expected outcomes (what the tester should see)
  - Map to acceptance criteria from the story
  """

  @qa_brief_result_path """
  Format:
  - Use H2 heading
  - Single line: file path

  Content:
  - Where the tester writes the result document
  """

  @qa_brief_setup_notes """
  Format:
  - Use H2 heading
  - Free-form paragraphs

  Content:
  - Additional context, prerequisites, known issues
  """

  @qa_result_status """
  Format:
  - Use H2 heading
  - Single line: pass, fail, or partial

  Content:
  - Overall test result for this story
  - `pass` — all scenarios passed
  - `fail` — one or more scenarios failed
  - `partial` — some scenarios could not be tested (e.g. camera hardware required)
  """

  @qa_result_scenarios """
  Format:
  - Use H2 heading
  - Use H3 for each scenario tested
  - Include pass/fail status, steps taken, and observations

  Content:
  - Each scenario from the brief's "what to test" section
  - What you did, what you saw, whether it matched expectations
  - Reference screenshot paths as evidence
  """

  @qa_result_evidence """
  Format:
  - Use H2 heading
  - Bullet list of screenshot/file paths

  Content:
  - Paths to screenshots captured during testing
  - Each entry should note what state it captures
  """

  @qa_result_issues """
  Format:
  - Use H2 heading
  - Use H3 for each issue title
  - Use H4 subsections for structured fields: Severity, Description, and optionally Scope
  - Severity must be one of: CRITICAL, HIGH, MEDIUM, LOW, INFO
  - Scope is optional, one of: APP, QA, DOCS (defaults to APP if omitted)
  - If no issues found, write "None" as plain text

  Content:
  - Each issue gets an H3 heading with a descriptive title
  - H4 `#### Severity` with the severity level on the next line
  - H4 `#### Scope` (optional) with the scope on the next line:
    - APP — bug in application code
    - QA — problem with QA infrastructure (seeds, auth scripts, test tooling)
    - DOCS — documentation gap or error
  - H4 `#### Description` with paragraphs describing what's wrong
  - Include specific URLs, inputs, or conditions that trigger the issue

  Examples:
  - ## Issues
    ### Login redirect fails for invited users
    #### Severity
    HIGH
    #### Description
    Invited users who click the email link are redirected to /login instead of /accept-invite.
    Reproduced with user test+invite@example.com.

    ### Seed script fails on fresh database
    #### Severity
    MEDIUM
    #### Scope
    QA
    #### Description
    Running `mix run priv/repo/qa_seeds.exs` on a freshly migrated database fails because it
    references a user that doesn't exist yet.
  """

  @qa_plan_app_overview """
  Format:
  - Use H2 heading
  - Brief paragraph (3-5 sentences)

  Content:
  - Tech stack (Phoenix, LiveView, Ecto, etc.)
  - How authentication works (session-based, token, etc.)
  - App port and base URL
  - Key route patterns and pipelines
  """

  @qa_plan_tools_registry """
  Format:
  - Use H2 heading
  - Use H3 for each testing approach

  Content:
  - For each tool: name, when to use, example invocation
  - Include shell scripts for controller/API testing with auth baked in
  - Cover: web tool (LiveView pages), curl (API/controller), mix run (seeds/setup)
  """

  @qa_plan_seed_strategy """
  Format:
  - Use H2 heading
  - Reference each `.exs` seed script with its `mix run` invocation
  - Document what entities each script creates and credentials it outputs

  Content:
  - How to run seed scripts: `mix run priv/repo/qa_seeds.exs`
  - What entities each script creates (users, accounts, domain records)
  - Credentials and URLs printed by the scripts
  - Which scripts to run for different testing scenarios
  """

  @qa_plan_system_issues """
  Format:
  - Use H2 heading
  - Use H3 for each issue
  - Each issue: what went wrong, workaround (if any), status (open/resolved)

  Content:
  - Infrastructure problems (server won't start, port conflicts, missing deps)
  - Auth or seed failures (script errors, credential issues)
  - Tool problems (browser automation flaky, curl auth not working)
  - Environment issues (database state, config mismatches)
  - Any blocker or friction the QA agent hit that should be fixed or noted
  """

  @qa_plan_notes """
  Format:
  - Use H2 heading
  - Free-form paragraphs

  Content:
  - Additional context, caveats, known limitations
  - Environment-specific notes
  """

  @qa_issue_status """
  Format:
  - Use H2 heading
  - Single line: one of `incoming`, `accepted`, `dismissed`

  Content:
  - incoming — issue has not been triaged yet
  - accepted — issue has been reviewed and accepted as a real problem
  - dismissed — issue has been reviewed and dismissed (not a bug, duplicate, etc.)
  """

  @qa_issue_scope """
  Format:
  - Use H2 heading
  - Single line: one of `app`, `qa`, `docs`

  Content:
  - app — bug in application code (controllers, live views, schemas, etc.)
  - qa — problem with QA infrastructure (seed scripts, auth scripts, test tooling)
  - docs — documentation gap or error (specs, README, user stories)
  """

  @qa_issue_severity """
  Format:
  - Use H2 heading
  - Single line: one of `critical`, `high`, `medium`, `low`, `info`

  Content:
  - critical — app crashes, data loss, security vulnerability
  - high — feature broken, wrong behavior
  - medium — UX problem, missing validation, edge case failure
  - low — minor cosmetic issue, non-blocking
  - info — observation, suggestion, or note
  """

  @qa_issue_description """
  Format:
  - Use H2 heading
  - Paragraphs describing the issue

  Content:
  - What's wrong, with enough detail to understand and reproduce
  - Include specific URLs, inputs, or conditions that trigger it
  """

  @qa_issue_source """
  Format:
  - Use H2 heading
  - Single line: reference to source (e.g., "QA Story 376")

  Content:
  - Which QA story discovered this issue
  - Path to the result file for traceability
  """

  @qa_issue_reproduction """
  Format:
  - Use H2 heading
  - Numbered steps to reproduce
  """

  @qa_issue_requirements_impact """
  Format:
  - Use H2 heading
  - Bullet list of affected requirements or stories

  Content:
  - Which user stories or requirements this issue impacts
  - Severity of impact on each
  """

  @qa_issue_resolution """
  Format:
  - Use H2 heading
  - Paragraphs describing what was done to resolve the issue

  Content:
  - Summary of the fix applied
  - Files changed
  - Verification steps taken
  """

  @adr_status """
  Format:
  - Use H2 heading
  - Single line with status value

  Content:
  - The current status of this decision
  - One of: Accepted, Accepted (pre-made), Proposed, Superseded
  - May include parenthetical qualifier (e.g., "Accepted (supersedes exvcr)")

  Examples:
  - ## Status
    Accepted
  - ## Status
    Accepted (pre-made)
  - ## Status
    Accepted (supersedes exvcr)
  """

  @adr_context """
  Format:
  - Use H2 heading
  - One or more paragraphs

  Content:
  - Why this decision was needed
  - What problem or requirement drove the decision
  - Relevant constraints or project requirements

  Examples:
  - ## Context
    We need a performant, productive web framework for building our application.
  """

  @adr_options_considered """
  Format:
  - Use H2 heading
  - Use H3 for each option name
  - Include **Pros:** and **Cons:** bullet lists

  Content:
  - Alternatives evaluated before making the decision
  - Each option with trade-off analysis
  - Not required for pre-made decisions where the choice is predetermined

  Examples:
  - ## Options Considered
    ### Option A: Wallaby
    - **Pros:** Real browser testing, JavaScript support
    - **Cons:** Requires ChromeDriver, slower tests
    ### Option B: Hound
    - **Pros:** Lightweight, fast
    - **Cons:** Less maintained, fewer features
  """

  @adr_decision """
  Format:
  - Use H2 heading
  - One or more paragraphs

  Content:
  - What was chosen and why
  - Reference specific project requirements or constraints
  - Include package names and versions where applicable

  Examples:
  - ## Decision
    Use Wallaby for browser-based integration testing. It provides real browser
    interaction via ChromeDriver and integrates well with Phoenix test infrastructure.
  """

  @adr_consequences """
  Format:
  - Use H2 heading
  - Bullet list or paragraphs

  Content:
  - Trade-offs accepted
  - Follow-up actions needed
  - Impact on development workflow or testing

  Examples:
  - ## Consequences
    - Req-based HTTP calls enable ReqCassette recording for deterministic tests
    - Each service can be independently mocked or recorded
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
  - Use H3 for each component module name (fully qualified, e.g., ### AppNameWeb.AccountLive.Dashboard)
  - Include bullet list with **Type:**, **Description:**, **Stories:**
  - For live_context types, include #### Children subsection listing LiveViews and LiveComponents

  Content:
  - Surface components are LiveViews, Controllers, Live Contexts, or Plugs (the UI layer)
  - Module names must start with AppNameWeb
  - Stories field lists story IDs that this surface handles (for dual mapping)
  - Type should be: liveview, liveview_component, live_context, controller, or module
  - Use `live_context` when a feature has multiple related LiveViews and/or shared LiveComponents
    under a namespace (e.g., UserLive with UserLive.Index, UserLive.Show, UserLive.FormComponent)
  - Use standalone `liveview` for single-page views with no siblings
  - Group related LiveViews under a context namespace: `AppWeb.{Context}Live.{Action}`
    This creates the conventional `live/{context}_live/` directory structure.

  Example:
  ## Surface Components

  ### MyAppWeb.UserLive

  - **Type:** live_context
  - **Description:** User management views and components
  - **Stories:** 1, 2, 3

  #### Children

  - MyAppWeb.UserLive.Index (liveview) [Stories: 1]: List all users with search
  - MyAppWeb.UserLive.Show (liveview) [Stories: 2]: Display user profile
  - MyAppWeb.UserLive.FormComponent (liveview_component) [Stories: 3]: User create/edit form

  ### MyAppWeb.AccountLive.Dashboard

  - **Type:** liveview
  - **Description:** Main dashboard showing account overview
  - **Stories:** 4, 5
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

  - MyAppWeb.AccountLive.Dashboard -> MyApp.Accounts
  - MyAppWeb.AccountLive.Dashboard -> MyApp.Reports
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
      required_sections: ["route", "user interactions", "dependencies", "design"],
      optional_sections: ["params", "components"],
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
    "live_context_spec" => %{
      overview: """
      Live context spec documents define a UI grouping of related LiveViews and
      LiveComponents under a shared namespace. They list the routed child views,
      shared components, and domain context dependencies.

      On evaluation, child spec stubs are created for both listed LiveViews and
      Components. Live contexts have no code file — they are spec-only groupings.
      """,
      required_sections: ["liveviews", "components", "dependencies"],
      optional_sections: [],
      allowed_additional_sections: [],
      section_descriptions: %{
        "type" => @spec_type,
        "liveviews" => @spec_live_context_liveviews,
        "components" => @spec_live_context_components,
        "dependencies" => @spec_dependencies
      }
    },
    "liveview_component" => %{
      overview: """
      LiveComponent spec documents define stateful Phoenix LiveComponents that
      receive assigns, handle their own events via phx-target={@myself}, and
      communicate with parent views via send(self(), msg).
      """,
      required_sections: ["assigns", "design"],
      optional_sections: ["events", "dependencies"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "type" => @spec_type,
        "assigns" => @spec_assigns,
        "events" => @spec_livecomponent_events,
        "design" => @spec_design,
        "dependencies" => @spec_dependencies
      }
    },
    "json" => %{
      overview: """
      JSON view modules render structured JSON responses for Phoenix controllers.
      They are companion files that don't require detailed specifications.
      """,
      required_sections: [],
      optional_sections: ["functions"],
      allowed_additional_sections: "*",
      section_descriptions: %{
        "type" => @spec_type,
        "functions" => @spec_functions
      }
    },
    "qa_story_brief" => %{
      overview: "Per-story QA testing brief. Written by the QA planner after reading the story's prompt file and the QA plan. Gives the tester exact instructions — tool, auth, seeds, what to test.",
      required_sections: ["tool", "auth", "seeds", "what to test", "result path"],
      optional_sections: ["setup notes"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "tool" => @qa_brief_tool,
        "auth" => @qa_brief_auth,
        "seeds" => @qa_brief_seeds,
        "what to test" => @qa_brief_what_to_test,
        "result path" => @qa_brief_result_path,
        "setup notes" => @qa_brief_setup_notes
      }
    },
    "qa_result" => %{
      overview: "Per-story QA test result. Written by the QA agent after executing the test scenarios from the brief. Records status, scenario outcomes, evidence, and issues found.",
      required_sections: ["status", "scenarios"],
      optional_sections: ["evidence", "issues"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "status" => @qa_result_status,
        "scenarios" => @qa_result_scenarios,
        "evidence" => @qa_result_evidence,
        "issues" => @qa_result_issues
      }
    },
    "qa_plan" => %{
      overview: "Overall QA testing strategy document. Written by the QA planner after analyzing the running app's routes, authentication, and configuration. Serves as the foundation for per-story QA briefs.",
      required_sections: ["app overview", "tools registry", "seed strategy"],
      optional_sections: ["system issues", "notes"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "app overview" => @qa_plan_app_overview,
        "tools registry" => @qa_plan_tools_registry,
        "seed strategy" => @qa_plan_seed_strategy,
        "system issues" => @qa_plan_system_issues,
        "notes" => @qa_plan_notes
      }
    },
    "qa_issue" => %{
      overview: "QA-discovered issue filed to .code_my_spec/issues/incoming/ for triage.",
      required_sections: ["status", "severity", "description"],
      optional_sections: ["scope", "source", "reproduction", "requirements impact", "resolution"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "status" => @qa_issue_status,
        "severity" => @qa_issue_severity,
        "scope" => @qa_issue_scope,
        "description" => @qa_issue_description,
        "source" => @qa_issue_source,
        "reproduction" => @qa_issue_reproduction,
        "requirements impact" => @qa_issue_requirements_impact,
        "resolution" => @qa_issue_resolution
      }
    },
    "adr" => %{
      overview: """
      Architecture Decision Records (ADRs) document technology choices for the project.
      Each ADR captures what was decided, why, what alternatives were considered, and
      the consequences of the decision. Pre-made decisions for the standard stack use
      a simplified format; researched decisions include detailed options analysis.
      """,
      required_sections: ["status", "context", "decision", "consequences"],
      optional_sections: ["options considered"],
      allowed_additional_sections: [],
      section_descriptions: %{
        "status" => @adr_status,
        "context" => @adr_context,
        "options considered" => @adr_options_considered,
        "decision" => @adr_decision,
        "consequences" => @adr_consequences
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
