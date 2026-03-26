defmodule CodeMySpec.AgentTasks.WriteBddSpecs do
  @moduledoc """
  Agent task for generating BDD specification files for a single story.

  Writes specs for one story at a time. Auto-selects the top-priority incomplete
  story if none specified in the session. Generates a comprehensive prompt covering
  all acceptance criteria for the story, validates all specs parse correctly, and
  checks compilation.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Compile
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Stories

  require Logger

  @spex_dir "test/spex"

  defp task_dir(story_id), do: "#{CodeMySpec.Paths.tasks_dir()}/stories/#{story_id}"

  defp prompt_dir(story_id),
    do: "#{task_dir(story_id)}/subagent_prompts"

  @doc """
  Generate the prompt for Claude to create BDD specification files for a story.

  If `task.story_id` is provided, writes specs for that story. Otherwise,
  auto-selects the top-priority incomplete story via `BddSpecs.get_next_incomplete_story/2`.

  Returns "all complete" message if no stories need specs.
  """
  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, task) do
    env = scope.environment
    working_dir = get_working_dir(env)

    with {:ok, _sync_result} <- maybe_sync_project(scope, working_dir, []),
         {:ok, story} <- resolve_story(scope, task, env),
         {:ok, component} <- get_story_component(scope, story) do
      ensure_app_spex_exists(env)
      ensure_shared_givens_exists(env)
      coverage = BddSpecs.check_story_coverage(env, story)

      prompt = build_story_prompt(env, story, component, coverage)

      file_path = "#{prompt_dir(story.id)}/bdd_specs_prompt.md"
      :ok = Environments.write_file(env, file_path, prompt)

      orchestration_content = build_orchestration_prompt(story, file_path)
      orchestration_path = "#{task_dir(story.id)}/write_bdd_specs.md"
      :ok = Environments.write_file(env, orchestration_path, orchestration_content)

      {:ok,
       "Your instructions have been written to: `#{orchestration_path}`\n\nRead this file to begin."}
    end
  end

  @doc """
  Validate all BDD specs for the current story.

  Returns `:valid` when all criteria have valid, parseable specs with scenarios.
  Returns `:invalid` with specific feedback for missing/invalid specs.
  Also runs `mix compile` to verify specs compile correctly.
  """
  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, task) do
    env = scope.environment

    with {:ok, story} <- resolve_story(scope, task, env),
         result <- validate_story_specs(env, story) do
      case result do
        {:ok, :valid} ->
          cleanup_task_dir(env, story.id)
          {:ok, :valid}

        other ->
          other
      end
    end
  end

  # ============================================================================
  # Story Resolution
  # ============================================================================

  defp resolve_story(scope, %{story_id: story_id}, _env) when not is_nil(story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp resolve_story(scope, _task, env) do
    case BddSpecs.get_next_incomplete_story(env, scope) do
      nil -> {:error, :all_stories_complete}
      story -> {:ok, story}
    end
  end

  # ============================================================================
  # Component Resolution
  # ============================================================================

  defp get_story_component(_scope, %{component_id: nil} = story) do
    Logger.warning(
      "[WriteBddSpecs] Story #{story.id} (#{story.title}) has no component_id linked"
    )

    {:error, :component_not_linked}
  end

  defp get_story_component(scope, %{component_id: component_id} = story) do
    case Components.get_component(scope, component_id) do
      nil ->
        Logger.warning(
          "[WriteBddSpecs] Story #{story.id} (#{story.title}) references component_id=#{component_id} but component not found"
        )

        {:error, :component_not_found}

      component ->
        {:ok, component}
    end
  end

  defp get_story_component(_scope, story) do
    Logger.warning("[WriteBddSpecs] Story #{inspect(story.id)} has no component_id field")
    {:error, :component_not_linked}
  end

  # ============================================================================
  # Project Sync
  # ============================================================================

  defp maybe_sync_project(scope, working_dir, opts) do
    if Keyword.get(opts, :skip_sync, false) do
      {:ok, :skipped}
    else
      do_sync_project(scope, working_dir)
    end
  end

  defp do_sync_project(scope, working_dir) do
    Logger.debug("[WriteBddSpecs] Incremental sync from #{working_dir}")

    case ProjectSync.incremental_sync(scope, base_dir: working_dir) do
      {:ok, _result} -> {:ok, :synced}
      {:error, reason} ->
        Logger.error("[WriteBddSpecs] Sync failed: #{inspect(reason)}")
        {:error, {:sync_failed, reason}}
    end
  end

  # ============================================================================
  # Environment Helpers
  # ============================================================================

  defp get_working_dir(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp get_working_dir(%{ref: %{working_dir: dir}}), do: dir
  defp get_working_dir(_), do: File.cwd!()

  # ============================================================================
  # App Spex Setup
  # ============================================================================

  defp ensure_app_spex_exists(env) do
    working_dir = get_working_dir(env)
    app_name = derive_app_name(working_dir)
    full_path = Path.join([working_dir, @spex_dir, "#{app_name}_spex.ex"])

    unless File.exists?(full_path) do
      full_path |> Path.dirname() |> File.mkdir_p!()
      app_module = derive_app_module(working_dir)
      spex_module = "#{app_module}Spex"
      web_module = "#{app_module}Web"
      test_module = "#{app_module}Test"

      content = """
      defmodule #{spex_module} do
        @moduledoc \"\"\"
        Boundary definition for BDD specifications.

        This boundary enforces surface-layer testing by only allowing dependencies
        on the Web layer and test support. Spex files cannot access context modules
        directly - all testing must go through the UI.
        \"\"\"

        use Boundary, deps: [#{web_module}, #{test_module}], exports: []
      end
      """

      File.write!(full_path, content)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_shared_givens_exists(env) do
    working_dir = get_working_dir(env)
    full_path = Path.join([working_dir, "test", "support", "shared_givens.ex"])

    unless File.exists?(full_path) do
      full_path |> Path.dirname() |> File.mkdir_p!()
      app_module = derive_app_module(working_dir)
      spex_module = "#{app_module}Spex"

      content = """
      defmodule #{spex_module}.SharedGivens do
        @moduledoc \"\"\"
        Shared given steps for BDD specifications.

        Import these givens in your spec files:

            defmodule #{spex_module}.FeatureNameSpex do
              use SexySpex
              import_givens #{spex_module}.SharedGivens.SharedGivens
              # ...
            end

        Add new shared givens here when you find yourself duplicating setup code
        across multiple specs. Remember: spex files can only access the Web layer,
        so shared givens should set up state through UI interactions, not fixtures.
        \"\"\"

        use SexySpex.Givens

        # Example shared given that sets up state through UI:
        #
        # given_ :user_registered, context do
        #   conn = Phoenix.ConnTest.build_conn()
        #   {:ok, view, _html} = Phoenix.LiveViewTest.live(conn, "/users/register")
        #
        #   view
        #   |> Phoenix.LiveViewTest.form("#registration-form", user: %{
        #     email: "test\#{System.unique_integer()}@example.com",
        #     password: "ValidPassword123!"
        #   })
        #   |> Phoenix.LiveViewTest.render_submit()
        #
        #   {:ok, %{}}
        # end
      end
      """

      File.write!(full_path, content)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp derive_app_name(working_dir) do
    mix_file = Path.join(working_dir, "mix.exs")

    if File.exists?(mix_file) do
      content = File.read!(mix_file)

      case Regex.run(~r/app:\s*:(\w+)/, content) do
        [_, app_name] -> app_name
        _ -> "my_app"
      end
    else
      "my_app"
    end
  end

  defp derive_app_module(working_dir) do
    working_dir
    |> derive_app_name()
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end

  defp shared_givens_path(env) do
    working_dir = get_working_dir(env)
    Path.join([working_dir, "test", "support", "shared_givens.ex"])
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_shared_givens(env) do
    full_path = shared_givens_path(env)

    if File.exists?(full_path) do
      File.read!(full_path)
    else
      ""
    end
  end

  # ============================================================================
  # Orchestration Prompt
  # ============================================================================

  defp build_orchestration_prompt(story, file_path) do
    """
    # Write BDD Specs: #{story.title}

    **Story ID**: #{story.id}

    A detailed prompt has been written to: `#{file_path}`

    ## Instructions

    Use the `@"CodeMySpec:bdd-spec-writer (agent)"` subagent to generate BDD specifications for this story.

    Pass it the prompt file path above. The prompt contains:
    - Story context and acceptance criteria with expected file paths
    - Component type and testing approach (LiveView, Controller, etc.)
    - Spex DSL syntax guide and shared givens

    The bdd-spec-writer agent will:
    1. Write ONE spec file per criterion
    2. Run `mix compile` to verify it compiles
    3. Stop and return for validation after each file

    After each spec file is written, validation will check that the file exists, parses correctly,
    has scenarios with Given/When/Then steps, and compiles. Fix any issues before proceeding to the next criterion.
    """
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_story_prompt(env, story, component, coverage) do
    working_dir = get_working_dir(env)
    app_name = derive_app_name(working_dir)
    app_module = derive_app_module(working_dir)
    spex_module = "#{app_module}Spex"
    app_spex_file = "#{@spex_dir}/#{app_name}_spex.ex"
    shared_givens_file = "test/support/shared_givens.ex"

    criteria = story.criteria || []
    shared_givens_content = read_shared_givens(env)
    component_type = component.type
    component_module = component.module_name

    criteria_sections =
      Enum.map_join(criteria, "\n\n", fn criterion ->
        build_criterion_section(story, criterion, coverage, component_type, spex_module)
      end)

    """
    # Write BDD Specifications for Story

    Create BDD specification files using the Spex DSL for the following story and its acceptance criteria.

    ## Story Context

    **ID**: #{story.id}
    **Title**: #{story.title}
    **Description**: #{story.description || "No description provided"}
    **Priority**: #{story.priority || "Not set"}

    ## Component Under Test

    **Module**: `#{component_module}`
    **Type**: #{component_type}

    ## Acceptance Criteria

    #{criteria_sections}

    #{build_testing_guide(component_type, spex_module)}

    ## Shared Givens

    Shared givens allow reusable setup steps across specs. The shared givens file is at:
    `#{shared_givens_file}`

    ### Current Shared Givens Content

    ```elixir
    #{shared_givens_content}
    ```

    ### Using Shared Givens

    To use shared givens in your spec file:

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex
      import_givens #{spex_module}.SharedGivens.SharedGivens

      spex "feature" do
        scenario "test case" do          # No context parameter on scenario
          given_ :user_registered        # Shared given - sets up state through UI
          given_ "specific setup", context do  # Inline given takes context when needed
            Map.put(context, :extra, true)
          end
          # ...
        end
      end
    end
    ```

    ### When to Add Shared Givens

    **Only add new shared givens if**:
    - You find yourself duplicating the same UI setup code across multiple specs
    - The setup is generic enough to be reused (e.g., "user is registered", "user is on dashboard")

    **Do NOT add shared givens for**:
    - One-off, scenario-specific setup
    - Setup that includes criterion-specific data

    **Remember**: Shared givens must set up state through the UI (LiveViewTest/ConnTest),
    not by calling context functions or fixtures directly.

    If you add a new shared given, update the `#{shared_givens_file}` file with the new definition.

    ## Testing Layer Guidelines

    **IMPORTANT**: Write specs at the SURFACE layer, not the domain layer.

    BDD specs should test user-facing behavior through the UI, not internal function calls.

    | Component Type | Testing Approach |
    |----------------|------------------|
    | LiveView (`*Web.*Live.*`) | `Phoenix.LiveViewTest` - mount, render, interact, assert HTML |
    | Controller (`*Web.*Controller`) | `Phoenix.ConnTest` - HTTP requests and responses |
    | Context (domain modules) | Only if explicitly testing pure business logic without UI |
    | Schema | Changeset validation tests |

    ### Surface Testing Principles

    - **Test what users SEE and DO** - not internal function calls
    - **Assert on HTML content** - text, elements, attributes users interact with
    - **Test user interactions** - form submissions, button clicks, navigation
    - **Assert on flash messages and redirects** - the feedback users receive
    - **Avoid calling context functions directly** - go through the UI layer

    For `*Web.*` modules, ALWAYS use LiveViewTest or ConnTest to simulate real user interactions.

    ## Spex DSL Syntax Guide

    Spex is a BDD framework for Elixir that uses Given/When/Then steps to describe behavior.

    ### Key Points

    1. **Module naming**: Use `#{spex_module}.FeatureNameSpex` convention (all specs under `#{spex_module}` boundary)
    2. **import_givens**: Import shared given definitions from `#{spex_module}.SharedGivens`
    3. **spex macro**: Wraps all scenarios for a feature
    4. **scenario macro**: Defines a specific test case. Context is implicitly available inside - do NOT pass it as a parameter.
    5. **given_/when_/then_ macros**: Define steps. Pass `context` when you need to read or update it.

    ### Context Availability

    - `context` is automatically available inside every scenario (from ExUnit setup)
    - Steps that need context take it as a parameter: `given_ "desc", context do`
    - Steps that don't need context omit it: `then_ "desc" do`
    - If a step takes context but doesn't use it, prefix with underscore: `given_ "desc", _context do`

    ### Step Return Values

    **IMPORTANT**: Steps must return specific values to update context correctly:

    - `given_` and `when_` steps that update context: Return `{:ok, updated_map}`
    - `given_` and `when_` steps that don't update context: Return `:ok`
    - `then_` steps: Return `:ok` after assertions
    - Returning a bare map raises `ArgumentError` — always wrap in `{:ok, map}`

    ```elixir
    given_ "user navigates to registration", context do
      {:ok, view, _html} = live(context.conn, "/users/register")
      {:ok, Map.put(context, :view, view)}
    end

    then_ "user sees welcome message", context do
      assert render(context.view) =~ "Welcome"
      :ok
    end
    ```

    ## Instructions

    **IMPORTANT: Write ONE spec file at a time, then STOP and wait for validation feedback.**

    Do not write multiple spec files in a single pass. Write one, let it be validated, fix any
    issues, then proceed to the next. This prevents cascading errors across multiple files.

    For each criterion:
    1. Create the spec file at the path specified
    2. **All spec modules must be under the `#{spex_module}` namespace** (e.g., `#{spex_module}.UserRegistrationSpex`)
    3. **Write actual test implementations** - NO TODOs or placeholder comments
    4. **Surface layer ONLY** - Do NOT call context functions, fixtures, or factories. All state setup must go through the UI.
    5. Use the testing patterns shown above for #{component_type} components
    6. Run `mix compile` to verify the spec compiles correctly
    7. **STOP and wait for validation** before writing the next spec
    8. Fix any validation errors before proceeding

    Reference files:
    - Boundary definition: `#{app_spex_file}`
    - Shared givens: `#{shared_givens_file}`
    """
  end

  defp build_criterion_section(story, criterion, coverage, component_type, spex_module) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    status = if criterion.id in coverage.covered, do: "✅ COVERED", else: "❌ MISSING"

    section = """
    ### Criterion #{criterion.id}: #{criterion.description}

    **Status**: #{status}
    **Expected File Path**: `#{spec_path}`
    """

    if criterion.id in coverage.missing do
      section <> "\n" <> build_criterion_guidance(component_type, spex_module)
    else
      section <> "\n_Spec already exists - skip unless revision needed._"
    end
  end

  defp build_criterion_guidance("liveview", spex_module) do
    app_module = String.replace(spex_module, "Spex", "")

    """
    **Testing Approach for LiveView (SURFACE LAYER):**
    - **Test what users SEE and DO** - not internal function calls
    - Use the project's existing `#{app_module}Web.ConnCase` - do NOT create additional case files
    - Use `Phoenix.LiveViewTest` for user interaction testing
    - Mount the LiveView with `live/2` - use plain string paths, not `~p` sigils
    - Use `form/3` + `render_submit/1` for form submissions
    - Use `element/3` + `render_click/1` for button clicks
    - Assert on HTML: `render/1 =~ "text"`, `has_element?/2`

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex
      use #{app_module}Web.ConnCase
      import Phoenix.LiveViewTest

      import_givens #{spex_module}.SharedGivens
    end
    ```
    """
  end

  defp build_criterion_guidance("controller", spex_module) do
    app_module = String.replace(spex_module, "Spex", "")

    """
    **Testing Approach for Controller (SURFACE LAYER):**
    - **Test HTTP requests and responses** - not internal function calls
    - Use the project's existing `#{app_module}Web.ConnCase` - do NOT create additional case files
    - Use `get/3`, `post/3`, `put/3`, `delete/3` for requests
    - Use plain string paths, not `~p` sigils
    - Assert with `html_response/2`, `json_response/2`, `redirected_to/1`

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex
      use #{app_module}Web.ConnCase

      import_givens #{spex_module}.SharedGivens
    end
    ```
    """
  end

  defp build_criterion_guidance(_type, spex_module) do
    """
    **Testing Approach:**
    - Use standard ExUnit assertions
    - Set up context in `given_` steps
    - Perform actions in `when_` steps
    - Assert outcomes in `then_` steps

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex

      import_givens #{spex_module}.SharedGivens
    end
    ```
    """
  end

  defp build_testing_guide("liveview", spex_module) do
    app_module = String.replace(spex_module, "Spex", "")
    conn_case = "#{app_module}Web.ConnCase"

    """
    ## LiveView Testing Guide

    This is a LiveView component. **Test at the SURFACE layer** using `Phoenix.LiveViewTest`.

    ### Key Principles

    - **Test what users SEE** - assert on rendered HTML, text content, element presence
    - **Test what users DO** - form submissions, button clicks, link navigation
    - **DON'T call context functions or fixtures** - all state setup through UI
    - **Assert on user feedback** - flash messages, error text, success confirmations

    ### Required Setup

    **IMPORTANT**: Use the project's existing `#{conn_case}` module. Do NOT create additional
    case files, and do NOT manually set `@endpoint` or `setup do` blocks for conn - `ConnCase`
    already provides these.

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex
      use #{conn_case}
      import Phoenix.LiveViewTest

      import_givens #{spex_module}.SharedGivens
    ```

    **Note:** Use plain strings for paths (e.g., `"/users/register"`) instead of the `~p` sigil.
    The `~p` sigil requires importing `Phoenix.VerifiedRoutes` and adds unnecessary dependencies.

    ### LiveView Testing Patterns

    **Mounting the LiveView:**
    ```elixir
    given_ "the registration page is loaded", context do
      {:ok, view, _html} = live(context.conn, "/users/register")
      {:ok, Map.put(context, :view, view)}
    end
    ```

    **Submitting forms (most common user action):**
    ```elixir
    when_ "user submits valid credentials", context do
      html = context.view
        |> form("#registration-form", user: %{email: "test@example.com", password: "SecurePass123!"})
        |> render_submit()
      {:ok, Map.put(context, :result_html, html)}
    end
    ```

    **Clicking buttons/links:**
    ```elixir
    when_ "user clicks the submit button", context do
      html = context.view |> element("button", "Submit") |> render_click()
      {:ok, Map.put(context, :html, html)}
    end
    ```

    **Asserting on visible content (what user sees):**
    ```elixir
    then_ "user sees success message", context do
      assert render(context.view) =~ "Welcome"
      :ok
    end

    then_ "user sees validation error", context do
      assert render(context.view) =~ "is invalid"
      :ok
    end
    ```

    **Asserting element presence:**
    ```elixir
    then_ "the form is displayed", context do
      assert has_element?(context.view, "#registration-form")
      :ok
    end
    ```

    **Asserting redirects (after successful actions):**
    ```elixir
    then_ "user is redirected to dashboard", context do
      assert_redirect(context.view, "/dashboard")
      :ok
    end
    ```

    ### Complete Example

    ```elixir
    defmodule #{spex_module}.UserRegistrationSpex do
      use SexySpex
      use #{conn_case}
      import Phoenix.LiveViewTest

      import_givens #{spex_module}.SharedGivens

      spex "User registration" do
        scenario "user registers with valid credentials", context do
          given_ "the registration page is loaded", context do
            {:ok, view, _html} = live(context.conn, "/users/register")
            {:ok, Map.put(context, :view, view)}
          end

          when_ "user submits valid credentials", context do
            html = context.view
              |> form("#registration-form", user: %{email: "test@example.com", password: "SecurePass123!"})
              |> render_submit()
            {:ok, Map.put(context, :result_html, html)}
          end

          then_ "user sees welcome message", context do
            # Assert on what the USER SEES - the rendered HTML
            assert render(context.view) =~ "Welcome"
            :ok
          end
        end

        scenario "user sees validation errors for invalid input", context do
          given_ "the registration page is loaded", context do
            {:ok, view, _html} = live(context.conn, "/users/register")
            {:ok, Map.put(context, :view, view)}
          end

          when_ "user submits invalid email", context do
            html = context.view
              |> form("#registration-form", user: %{email: "invalid", password: "short"})
              |> render_submit()
            {:ok, Map.put(context, :result_html, html)}
          end

          then_ "user sees error messages", context do
            html = render(context.view)
            assert html =~ "must have the @ sign"
            assert html =~ "should be at least"
            :ok
          end
        end
      end
    end
    ```
    """
  end

  defp build_testing_guide("controller", spex_module) do
    app_module = String.replace(spex_module, "Spex", "")
    conn_case = "#{app_module}Web.ConnCase"

    """
    ## Controller Testing Guide

    This is a Controller. **Test at the SURFACE layer** using `Phoenix.ConnTest`.

    ### Key Principles

    - **Test HTTP requests and responses** - what users/clients send and receive
    - **Assert on response bodies** - HTML content, JSON payloads
    - **Assert on status codes** - 200, 201, 302, 404, etc.
    - **DON'T call context functions or fixtures** - all state setup through HTTP

    ### Required Setup

    **IMPORTANT**: Use the project's existing `#{conn_case}` module. Do NOT create additional
    case files, and do NOT manually set `@endpoint` or `setup do` blocks for conn - `ConnCase`
    already provides these.

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex
      use #{conn_case}

      import_givens #{spex_module}.SharedGivens
    ```

    **Note:** Use plain strings for paths (e.g., `"/api/resource"`) instead of the `~p` sigil
    to avoid dependencies on `Phoenix.VerifiedRoutes`.

    ### Controller Testing Patterns

    **Making GET requests:**
    ```elixir
    when_ "user visits the page", context do
      conn = get(context.conn, "/api/resource")
      Map.put(context, :conn, conn)
    end
    ```

    **Making POST requests:**
    ```elixir
    when_ "user submits data", context do
      conn = post(context.conn, "/api/resource", %{name: "Test"})
      Map.put(context, :conn, conn)
    end
    ```

    **Asserting HTML response:**
    ```elixir
    then_ "user sees the page", context do
      assert html_response(context.conn, 200) =~ "Welcome"
      :ok
    end
    ```

    **Asserting JSON response:**
    ```elixir
    then_ "API returns the data", context do
      assert %{"id" => _, "name" => "Test"} = json_response(context.conn, 200)
      :ok
    end
    ```

    **Asserting redirects:**
    ```elixir
    then_ "user is redirected to dashboard", context do
      assert redirected_to(context.conn) == "/dashboard"
      :ok
    end
    ```

    ### Complete Example

    ```elixir
    defmodule #{spex_module}.ResourceManagementSpex do
      use SexySpex
      use #{conn_case}

      import_givens #{spex_module}.SharedGivens

      spex "Resource management" do
        scenario "user creates resource successfully", context do
          when_ "user submits valid data", context do
            conn = post(context.conn, "/api/resources", %{
              resource: %{name: "Test Resource"}
            })
            Map.put(context, :conn, conn)
          end

          then_ "API returns created resource", context do
            # Assert on what the CLIENT RECEIVES - the JSON response
            assert %{"id" => id, "name" => "Test Resource"} = json_response(context.conn, 201)
            assert is_binary(id)
            :ok
          end
        end
      end
    end
    ```
    """
  end

  defp build_testing_guide(_type, spex_module) do
    """
    ## Testing Guide

    Use standard ExUnit assertions to test the behavior.

    ### Required Setup

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex

      import_givens #{spex_module}.SharedGivens
    ```

    ### Testing Patterns

    **Setting up context through UI:**
    ```elixir
    given_ "user navigates to page", context do
      {:ok, view, _html} = live(context.conn, "/some/page")
      {:ok, Map.put(context, :view, view)}
    end
    ```

    **Performing actions:**
    ```elixir
    when_ "user submits form", context do
      html = context.view |> form("#form", data: %{field: "value"}) |> render_submit()
      {:ok, Map.put(context, :html, html)}
    end
    ```

    **Asserting outcomes:**
    ```elixir
    then_ "user sees result", context do
      assert render(context.view) =~ "Success"
      :ok
    end
    ```
    """
  end

  # ============================================================================
  # Task Directory Cleanup
  # ============================================================================

  defp cleanup_task_dir(env, story_id) do
    dir = task_dir(story_id)
    working_dir = get_working_dir(env)
    full_dir = Path.join(working_dir, dir)

    if File.exists?(full_dir) and File.dir?(full_dir) do
      File.rm_rf(full_dir)
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_story_specs(env, story) do
    criteria = story.criteria || []

    validation_results =
      criteria
      |> Enum.map(fn criterion ->
        spec_path = BddSpecs.spec_file_path(story, criterion)
        full_path = Path.join(get_working_dir(env), spec_path)
        {criterion, spec_path, validate_single_spec(full_path)}
      end)

    errors =
      validation_results
      |> Enum.filter(fn {_criterion, _spec_path, result} -> result != :ok end)
      |> Enum.map(fn {criterion, spec_path, {:error, reason}} ->
        "Criterion #{criterion.id} (#{criterion.description}): #{format_error(reason)}\n  Expected file: `#{spec_path}`"
      end)

    if Enum.empty?(errors) do
      # All specs valid, check compilation
      validate_compilation(env)
    else
      feedback = """
      The following specs have issues:

      #{Enum.join(errors, "\n\n")}

      Please fix these issues and try again.
      """

      {:ok, :invalid, feedback}
    end
  end

  defp validate_single_spec(spec_path) do
    if File.exists?(spec_path) do
      case Parser.parse_file(spec_path) do
        {:ok, spec} ->
          validate_spec_content(spec)

        {:error, reason} ->
          {:error, {:parse_error, reason}}
      end
    else
      {:error, :file_not_found}
    end
  end

  defp validate_spec_content(spec) do
    cond do
      Enum.empty?(spec.scenarios) ->
        {:error, :no_scenarios}

      not scenarios_have_steps?(spec.scenarios) ->
        {:error, :missing_steps}

      true ->
        :ok
    end
  end

  defp scenarios_have_steps?(scenarios) do
    Enum.all?(scenarios, fn scenario ->
      not Enum.empty?(scenario.given_steps) or
        not Enum.empty?(scenario.when_steps) or
        not Enum.empty?(scenario.then_steps)
    end)
  end

  defp validate_compilation(env) do
    working_dir = get_working_dir(env)
    result = Compile.execute(cwd: working_dir)

    case result do
      %{status: :ok} ->
        {:ok, :valid}

      %{status: :error, data: %{compiler_results: diagnostics}} ->
        feedback = format_compilation_feedback(diagnostics)
        {:ok, :invalid, feedback}
    end
  end

  defp format_compilation_feedback(diagnostics) when is_list(diagnostics) do
    errors =
      Enum.map_join(diagnostics, "\n", fn diagnostic ->
        file = Map.get(diagnostic, :file) || Map.get(diagnostic, "file") || "unknown"

        message =
          Map.get(diagnostic, :message) || Map.get(diagnostic, "message") || "unknown error"

        position = Map.get(diagnostic, :position) || Map.get(diagnostic, "position")
        line = if position, do: Map.get(position, :line) || Map.get(position, "line"), else: nil

        if line do
          "  #{file}:#{line}: #{message}"
        else
          "  #{file}: #{message}"
        end
      end)

    """
    Compilation failed with errors:

    ```
    #{errors}
    ```

    Please fix the compilation issues and try again.
    """
  end

  defp format_compilation_feedback(output) when is_binary(output) do
    """
    Compilation failed with errors:

    ```
    #{output}
    ```

    Please fix the compilation issues and try again.
    """
  end

  defp format_compilation_feedback(_other) do
    """
    Compilation failed. Please check for syntax errors and try again.
    """
  end

  defp format_error(:file_not_found), do: "Spec file not found"
  defp format_error(:no_scenarios), do: "Spec must contain at least one scenario"
  defp format_error(:missing_steps), do: "All scenarios must have Given/When/Then steps"
  defp format_error({:parse_error, reason}), do: "Parse error: #{inspect(reason)}"
  defp format_error(other), do: inspect(other)
end
