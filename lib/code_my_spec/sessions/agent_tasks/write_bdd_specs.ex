defmodule CodeMySpec.Sessions.AgentTasks.WriteBddSpecs do
  @moduledoc """
  Agent task for generating BDD specification files for a single story.

  Writes specs for one story at a time. Auto-selects the top-priority incomplete
  story if none specified in the session. Generates a comprehensive prompt covering
  all acceptance criteria for the story, validates all specs parse correctly, and
  checks compilation.
  """

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Components
  alias CodeMySpec.Stories

  @shared_givens_path "test/spex/support/shared_givens.ex"

  @doc """
  Generate the prompt for Claude to create BDD specification files for a story.

  If `session.story_id` is provided, writes specs for that story. Otherwise,
  auto-selects the top-priority incomplete story via `BddSpecs.get_next_incomplete_story/2`.

  Returns "all complete" message if no stories need specs.
  """
  @spec command(term(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, session, _opts \\ []) do
    env = get_environment(session)

    with {:ok, story} <- resolve_story(scope, session, env),
         {:ok, component} <- get_story_component(scope, story) do
      ensure_shared_givens_exists(env)
      coverage = BddSpecs.check_story_coverage(env, story)

      prompt = build_story_prompt(env, story, component, coverage)
      {:ok, prompt}
    end
  end

  @doc """
  Validate all BDD specs for the current story.

  Returns `:valid` when all criteria have valid, parseable specs with scenarios.
  Returns `:invalid` with specific feedback for missing/invalid specs.
  Also runs `mix compile` to verify specs compile correctly.
  """
  @spec evaluate(term(), map(), keyword()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, session, _opts \\ []) do
    env = get_environment(session)

    with {:ok, story} <- resolve_story(scope, session, env) do
      validate_story_specs(env, story)
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

  defp resolve_story(_scope, %{story: %{id: _} = story}, _env) do
    # Story already embedded in session
    {:ok, story}
  end

  defp resolve_story(scope, _session, env) do
    case BddSpecs.get_next_incomplete_story(env, scope) do
      nil -> {:error, :all_stories_complete}
      story -> {:ok, story}
    end
  end

  # ============================================================================
  # Component Resolution
  # ============================================================================

  defp get_story_component(_scope, %{component_id: nil}) do
    {:error, :component_not_linked}
  end

  defp get_story_component(scope, %{component_id: component_id}) do
    case Components.get_component(scope, component_id) do
      nil -> {:error, :component_not_found}
      component -> {:ok, component}
    end
  end

  defp get_story_component(_scope, _story) do
    {:error, :component_not_linked}
  end

  # ============================================================================
  # Environment Helpers
  # ============================================================================

  defp get_environment(%{environment: %{cwd: _} = env}), do: env

  defp get_environment(%{environment: %{ref: %{working_dir: dir}}}) do
    %{type: :local, cwd: dir, ref: %{working_dir: dir}}
  end

  defp get_environment(_session) do
    cwd = File.cwd!()
    %{type: :local, cwd: cwd, ref: %{working_dir: cwd}}
  end

  defp get_working_dir(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp get_working_dir(%{ref: %{working_dir: dir}}), do: dir
  defp get_working_dir(_), do: File.cwd!()

  # ============================================================================
  # Shared Givens
  # ============================================================================

  defp ensure_shared_givens_exists(env) do
    working_dir = get_working_dir(env)
    full_path = Path.join(working_dir, @shared_givens_path)

    unless File.exists?(full_path) do
      full_path |> Path.dirname() |> File.mkdir_p!()
      app_module = derive_app_module(working_dir)

      content = """
      defmodule #{app_module}.SharedGivens do
        @moduledoc \"\"\"
        Shared given steps for BDD specifications.

        Import these givens in your spec files:

            Code.require_file("support/shared_givens.ex", __DIR__)

            defmodule MyApp.FeatureSpex do
              use Spex
              import_givens #{app_module}.SharedGivens
              # ...
            end

        Add new shared givens here when you find yourself duplicating setup code
        across multiple specs.
        \"\"\"

        use SexySpex.Givens

        # Example shared given:
        #
        # given_ :user_exists do
        #   user = MyApp.Fixtures.user_fixture()
        #   {:ok, %{user: user}}
        # end
      end
      """

      File.write!(full_path, content)
    end
  end

  defp derive_app_module(working_dir) do
    mix_file = Path.join(working_dir, "mix.exs")

    if File.exists?(mix_file) do
      content = File.read!(mix_file)

      case Regex.run(~r/app:\s*:(\w+)/, content) do
        [_, app_name] ->
          app_name
          |> String.split("_")
          |> Enum.map(&String.capitalize/1)
          |> Enum.join("")

        _ ->
          "MyApp"
      end
    else
      "MyApp"
    end
  end

  defp read_shared_givens(env) do
    working_dir = get_working_dir(env)
    full_path = Path.join(working_dir, @shared_givens_path)

    if File.exists?(full_path) do
      File.read!(full_path)
    else
      ""
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_story_prompt(env, story, component, coverage) do
    criteria = story.criteria || []
    shared_givens_content = read_shared_givens(env)
    component_type = component.type
    component_module = component.module_name

    criteria_sections =
      criteria
      |> Enum.map(fn criterion ->
        build_criterion_section(story, criterion, coverage, component_type, component_module)
      end)
      |> Enum.join("\n\n")

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

    #{build_testing_guide(component_type, component_module)}

    ## Shared Givens

    Shared givens allow reusable setup steps across specs. The shared givens file is at:
    `#{@shared_givens_path}`

    ### Current Shared Givens Content

    ```elixir
    #{shared_givens_content}
    ```

    ### Using Shared Givens

    To use shared givens in your spec file:

    ```elixir
    Code.require_file("support/shared_givens.ex", __DIR__)

    defmodule MyApp.FeatureNameSpex do
      use Spex
      import_givens MyApp.SharedGivens

      spex "feature" do
        scenario "test case", context do
          given_ :user_exists           # Shared given - context passed automatically
          given_ "specific setup", context do  # Inline given for unique cases
            {:ok, Map.put(context, :extra, true)}
          end
          # ...
        end
      end
    end
    ```

    ### When to Add Shared Givens

    **Only add new shared givens if**:
    - You find yourself duplicating the same setup code across multiple specs
    - The setup is generic enough to be reused (e.g., "user exists", "database is seeded")

    **Do NOT add shared givens for**:
    - One-off, scenario-specific setup
    - Setup that includes criterion-specific data

    If you add a new shared given, update the `#{@shared_givens_path}` file with the new definition.

    ## Spex DSL Syntax Guide

    Spex is a BDD framework for Elixir that uses Given/When/Then steps to describe behavior.

    ### Key Points

    1. **Module naming**: Use `MyApp.FeatureNameSpex` convention
    2. **Code.require_file**: Include at top to load shared givens
    3. **import_givens**: Import shared given definitions
    4. **spex macro**: Wraps all scenarios for a feature
    5. **scenario macro**: Defines a specific test case (takes context as second arg)
    6. **given_ macro**: Sets up preconditions (note the underscore suffix)
    7. **when_ macro**: Performs the action being tested
    8. **then_ macro**: Asserts expected outcomes

    ### Step Return Values

    - `given_` and `when_` steps should return `{:ok, context}` with any updates
    - `then_` steps should use assertions and return `:ok`
    - Context is passed through each step in order

    ## Instructions

    1. Read the shared givens file at `#{@shared_givens_path}` to see available shared steps
    2. Read the component spec file if it exists to understand the interface
    3. Create spec files at the paths specified for each missing criterion
    4. **Write actual test implementations** - NO TODOs or placeholder comments
    5. Use the testing patterns shown above for #{component_type} components
    6. Use shared givens where applicable; add new ones only if duplicating setup
    7. Run `mix compile` to verify the specs compile correctly
    8. If compilation fails, fix the errors before completing
    """
  end

  defp build_criterion_section(story, criterion, coverage, component_type, component_module) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    status = if criterion.id in coverage.covered, do: "✅ COVERED", else: "❌ MISSING"

    section = """
    ### Criterion #{criterion.id}: #{criterion.description}

    **Status**: #{status}
    **Expected File Path**: `#{spec_path}`
    """

    if criterion.id in coverage.missing do
      section <> "\n" <> build_criterion_guidance(component_type, component_module)
    else
      section <> "\n_Spec already exists - skip unless revision needed._"
    end
  end

  defp build_criterion_guidance("liveview", module_name) do
    """
    **Testing Approach for LiveView:**
    - Use `Phoenix.LiveViewTest` for user interaction testing
    - Mount the LiveView with `live/2` or `live/3`
    - Use `element/3` + `render_click/1` for button clicks
    - Use `form/3` + `render_submit/1` for form submissions
    - Assert with `has_element?/2` and `render/1 =~ "text"`

    ```elixir
    # Example structure for #{module_name}
    defmodule #{module_name}Spex do
      use Spex
      import Phoenix.LiveViewTest
      import Phoenix.ConnTest, only: [build_conn: 0]

      @endpoint MyAppWeb.Endpoint

      # ... scenarios ...
    end
    ```
    """
  end

  defp build_criterion_guidance("controller", module_name) do
    """
    **Testing Approach for Controller:**
    - Use `Phoenix.ConnTest` for HTTP request/response testing
    - Use `get/3`, `post/3`, `put/3`, `delete/3` for requests
    - Assert with `html_response/2`, `json_response/2`, `redirected_to/1`

    ```elixir
    # Example structure for #{module_name}
    defmodule #{module_name}Spex do
      use Spex
      import Phoenix.ConnTest

      @endpoint MyAppWeb.Endpoint

      # ... scenarios ...
    end
    ```
    """
  end

  defp build_criterion_guidance(_type, module_name) do
    """
    **Testing Approach:**
    - Use standard ExUnit assertions
    - Set up context in `given_` steps
    - Perform actions in `when_` steps
    - Assert outcomes in `then_` steps

    ```elixir
    # Example structure for #{module_name}
    defmodule #{module_name}Spex do
      use Spex

      # ... scenarios ...
    end
    ```
    """
  end

  defp build_testing_guide("liveview", module_name) do
    """
    ## LiveView Testing Guide

    This is a LiveView component. Use `Phoenix.LiveViewTest` to test user interactions.

    ### Required Setup

    ```elixir
    Code.require_file("support/shared_givens.ex", __DIR__)

    defmodule #{module_name}Spex do
      use Spex
      import Phoenix.LiveViewTest
      import Phoenix.ConnTest, only: [build_conn: 0]

      @endpoint MyAppWeb.Endpoint

      import_givens MyApp.SharedGivens
    ```

    ### LiveView Testing Patterns

    **Mounting the LiveView:**
    ```elixir
    given_ "user is on the page", context do
      conn = build_conn() |> log_in_user(context.user)
      {:ok, view, _html} = live(conn, ~p"/path/to/page")
      {:ok, Map.put(context, :view, view)}
    end
    ```

    **Clicking buttons/links:**
    ```elixir
    when_ "user clicks the submit button", context do
      html = context.view |> element("button", "Submit") |> render_click()
      {:ok, Map.put(context, :html, html)}
    end
    ```

    **Filling forms:**
    ```elixir
    when_ "user fills in the form", context do
      html = context.view
        |> form("#my-form", %{field: "value"})
        |> render_submit()
      {:ok, Map.put(context, :html, html)}
    end
    ```

    **Asserting content:**
    ```elixir
    then_ "user sees success message", context do
      assert render(context.view) =~ "Success!"
      :ok
    end
    ```

    **Asserting element presence:**
    ```elixir
    then_ "the item appears in the list", context do
      assert has_element?(context.view, "#item-123")
      :ok
    end
    ```

    ### Complete Example

    ```elixir
    Code.require_file("support/shared_givens.ex", __DIR__)

    defmodule #{module_name}Spex do
      use Spex
      import Phoenix.LiveViewTest
      import Phoenix.ConnTest, only: [build_conn: 0]

      @endpoint MyAppWeb.Endpoint

      import_givens MyApp.SharedGivens

      spex "feature name" do
        scenario "user completes action successfully", context do
          given_ :user_exists

          given_ "user is on the page", context do
            conn = build_conn() |> log_in_user(context.user)
            {:ok, view, _html} = live(conn, ~p"/the/path")
            {:ok, Map.put(context, :view, view)}
          end

          when_ "user submits the form", context do
            html = context.view
              |> form("#the-form", %{name: "Test"})
              |> render_submit()
            {:ok, Map.put(context, :html, html)}
          end

          then_ "user sees confirmation", context do
            assert render(context.view) =~ "Created successfully"
            :ok
          end
        end
      end
    end
    ```
    """
  end

  defp build_testing_guide("controller", module_name) do
    """
    ## Controller Testing Guide

    This is a Controller. Use `Phoenix.ConnTest` to test HTTP requests and responses.

    ### Required Setup

    ```elixir
    Code.require_file("support/shared_givens.ex", __DIR__)

    defmodule #{module_name}Spex do
      use Spex
      import Phoenix.ConnTest

      @endpoint MyAppWeb.Endpoint

      import_givens MyApp.SharedGivens
    ```

    ### Controller Testing Patterns

    **Setting up authenticated conn:**
    ```elixir
    given_ "user is authenticated", context do
      conn = build_conn() |> log_in_user(context.user)
      {:ok, Map.put(context, :conn, conn)}
    end
    ```

    **Making GET requests:**
    ```elixir
    when_ "user visits the page", context do
      conn = get(context.conn, ~p"/api/resource")
      {:ok, Map.put(context, :conn, conn)}
    end
    ```

    **Making POST requests:**
    ```elixir
    when_ "user submits data", context do
      conn = post(context.conn, ~p"/api/resource", %{name: "Test"})
      {:ok, Map.put(context, :conn, conn)}
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
      assert redirected_to(context.conn) == ~p"/dashboard"
      :ok
    end
    ```

    ### Complete Example

    ```elixir
    Code.require_file("support/shared_givens.ex", __DIR__)

    defmodule #{module_name}Spex do
      use Spex
      import Phoenix.ConnTest

      @endpoint MyAppWeb.Endpoint

      import_givens MyApp.SharedGivens

      spex "feature name" do
        scenario "user creates resource successfully", context do
          given_ :user_exists

          given_ "user is authenticated", context do
            conn = build_conn() |> log_in_user(context.user)
            {:ok, Map.put(context, :conn, conn)}
          end

          when_ "user submits valid data", context do
            conn = post(context.conn, ~p"/api/resources", %{
              resource: %{name: "Test Resource"}
            })
            {:ok, Map.put(context, :conn, conn)}
          end

          then_ "resource is created", context do
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

  defp build_testing_guide(_type, module_name) do
    """
    ## Testing Guide

    Use standard ExUnit assertions to test the behavior.

    ### Required Setup

    ```elixir
    Code.require_file("support/shared_givens.ex", __DIR__)

    defmodule #{module_name}Spex do
      use Spex

      import_givens MyApp.SharedGivens
    ```

    ### Testing Patterns

    **Setting up context:**
    ```elixir
    given_ "precondition exists", context do
      data = create_test_data()
      {:ok, Map.put(context, :data, data)}
    end
    ```

    **Performing actions:**
    ```elixir
    when_ "action is performed", context do
      result = perform_action(context.data)
      {:ok, Map.put(context, :result, result)}
    end
    ```

    **Asserting outcomes:**
    ```elixir
    then_ "expected outcome occurs", context do
      assert context.result == expected_value()
      :ok
    end
    ```
    """
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
        {criterion, validate_single_spec(full_path)}
      end)

    errors =
      validation_results
      |> Enum.filter(fn {_criterion, result} -> result != :ok end)
      |> Enum.map(fn {criterion, {:error, reason}} ->
        "Criterion #{criterion.id} (#{criterion.description}): #{format_error(reason)}"
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
    cond do
      not File.exists?(spec_path) ->
        {:error, :file_not_found}

      true ->
        case Parser.parse_file(spec_path) do
          {:ok, spec} ->
            validate_spec_content(spec)

          {:error, reason} ->
            {:error, {:parse_error, reason}}
        end
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

    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           cd: working_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, :valid}

      {output, _exit_code} ->
        feedback = """
        Compilation failed with warnings or errors:

        ```
        #{output}
        ```

        Please fix the compilation issues and try again.
        """

        {:ok, :invalid, feedback}
    end
  end

  defp format_error(:file_not_found), do: "Spec file not found"
  defp format_error(:no_scenarios), do: "Spec must contain at least one scenario"
  defp format_error(:missing_steps), do: "All scenarios must have Given/When/Then steps"
  defp format_error({:parse_error, reason}), do: "Parse error: #{inspect(reason)}"
  defp format_error(other), do: inspect(other)
end
