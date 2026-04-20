defmodule CodeMySpec.AgentTasks.WriteBddSpecs do
  @moduledoc """
  Agent task for generating BDD specification files for a story.

  Returns a prompt telling the agent how to write BDD specs for the story's
  acceptance criteria. The prompt includes the Spex DSL guide, testing patterns
  for the component type, and per-criterion file paths.
  """

  def analyzers, do: [:spex_stale]

  def orchestrate(node) do
    "Spawn a @spec-writer sub-agent to call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Compile
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Stories

  require Logger

  @spex_dir "test/spex"

  # ============================================================================
  # Command — build and return the prompt
  # ============================================================================

  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, task) do
    with {:ok, story} <- resolve_story(scope, task),
         {:ok, component} <- get_story_component(scope, story) do
      app_name = derive_app_name(scope)
      app_module = camelize(app_name)
      spex_module = "#{app_module}Spex"

      prompt = build_prompt(story, component, app_name, app_module, spex_module)
      {:ok, prompt}
    end
  end

  # ============================================================================
  # Evaluate — check that spec files exist, parse, and compile
  # ============================================================================

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, task) do
    with {:ok, story} <- resolve_story(scope, task) do
      validate_story_specs(scope, story)
    end
  end

  # ============================================================================
  # Story / Component Resolution
  # ============================================================================

  defp resolve_story(scope, %{story_id: story_id}) when not is_nil(story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp resolve_story(_scope, _task), do: {:error, :story_not_specified}

  defp get_story_component(_scope, %{component_id: nil} = story) do
    Logger.warning("[WriteBddSpecs] Story #{story.id} (#{story.title}) has no component linked")
    {:error, :component_not_linked}
  end

  defp get_story_component(scope, %{component_id: component_id} = story) do
    case Components.get_component(scope, component_id) do
      nil ->
        Logger.warning("[WriteBddSpecs] Story #{story.id} component #{component_id} not found")
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
  # Prompt
  # ============================================================================

  defp build_prompt(story, component, app_name, app_module, spex_module) do
    criteria = story.criteria || []
    component_type = component.type
    conn_case = "#{app_module}Web.ConnCase"

    criteria_sections =
      Enum.map_join(criteria, "\n\n", fn criterion ->
        spec_path = BddSpecs.spec_file_path(story, criterion)

        """
        ### Criterion #{criterion.id}: #{criterion.description}

        **Expected File Path**: `#{spec_path}`
        """
      end)

    """
    # Write BDD Specs: #{story.title}

    **Story ID**: #{story.id}
    **Description**: #{story.description || "No description"}
    **Component**: `#{component.module_name}` (#{component_type})

    ## Component Under Test

    #{component_context_section(component)}

    #{sibling_specs_section(story, criteria)}

    ## Acceptance Criteria

    #{criteria_sections}

    ## Instructions

    Write ONE spec file per criterion, then STOP for validation.

    For each criterion:
    1. Create the spec file at the path shown above
    2. All spec modules must be under the `#{spex_module}` namespace
    3. Write actual test implementations — no TODOs or placeholders
    4. Drive the real interaction surface only — engineers interact
       through LiveView, agents through files + HTTP hooks + MCP tools.
       Never call context functions directly from `when_` / `then_`
       steps; never read the DB from `then_`
    5. Run `mix compile` to verify
    6. STOP and wait for validation before the next spec

    #{testing_setup(component_type, conn_case, spex_module)}

    ## Spex DSL Quick Reference

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use SexySpex
      #{if component_type in ["liveview", "controller"], do: "use #{conn_case}\n      import Phoenix.LiveViewTest\n", else: ""}
      spex "feature name" do
        scenario "description" do
          given_ "setup", context do
            # Return {:ok, updated_context} or :ok
            {:ok, Map.put(context, :key, value)}
          end

          when_ "action", context do
            {:ok, Map.put(context, :result, value)}
          end

          then_ "assertion", context do
            assert context.result == expected
            :ok
          end
        end
      end
    end
    ```

    ### Step return values
    - `given_` / `when_` that update context: `{:ok, updated_map}`
    - `given_` / `when_` that don't: `:ok`
    - `then_`: `:ok` after assertions
    - Never return a bare map — wrap in `{:ok, map}`

    ## Reference Files
    - Boundary definition: `#{@spex_dir}/#{app_name}_spex.ex`
    - Shared givens: `test/support/shared_givens.ex`
    """
  end

  # Surfaces the component's source location and @moduledoc so the
  # spec-writer can see the real public interface rather than
  # grepping blind.
  defp component_context_section(%{module_name: module_name}) do
    path = module_path(module_name)

    case path && File.read(path) do
      {:ok, source} ->
        """
        Source: `#{path}`

        #{extract_moduledoc(source)}
        """

      _ ->
        """
        Source: `#{inferred_path_hint(module_name)}` (couldn't read — read the file before writing specs to see the public API)
        """
    end
  end

  # If other specs in the same story already exist, point at one so
  # the author can copy the established pattern (setup blocks, fixture
  # paths, shared givens, module namespace) rather than reinventing.
  defp sibling_specs_section(story, criteria) do
    dir = story_spec_dir(story, criteria)

    case dir && list_existing_specs(dir) do
      [_ | _] = existing ->
        bullets = Enum.map_join(existing, "\n", &"    - `#{&1}`")

        """
        ## Sibling Specs in This Story

        Other criteria in this story have already been written. Read at
        least one end-to-end as a template for shared setup, fixture
        paths, case template, and given usage:

        #{bullets}
        """

      _ ->
        ""
    end
  end

  defp module_path(module_name) when is_binary(module_name) do
    relative =
      module_name
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    candidates = ["lib/#{relative}.ex", "#{relative}.ex"]
    Enum.find(candidates, &File.exists?/1)
  end

  defp module_path(_), do: nil

  defp inferred_path_hint(module_name) when is_binary(module_name) do
    relative =
      module_name
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    "lib/#{relative}.ex"
  end

  defp inferred_path_hint(_), do: "lib/<path>.ex"

  defp extract_moduledoc(source) do
    case Regex.run(~r/@moduledoc\s+"""\n(.*?)\n\s*"""/s, source) do
      [_, doc] ->
        trimmed = String.trim(doc)
        "### Module documentation\n\n#{trimmed}"

      _ ->
        "(No @moduledoc; read the file to understand the public API.)"
    end
  end

  defp story_spec_dir(story, [first | _]) do
    Path.dirname(BddSpecs.spec_file_path(story, first))
  end

  defp story_spec_dir(_story, _), do: nil

  defp list_existing_specs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, "_spex.exs"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp testing_setup("liveview", conn_case, spex_module) do
    """
    ## LiveView Testing

    Use `Phoenix.LiveViewTest`. Test what users SEE and DO.

    ```elixir
    defmodule #{spex_module}.FeatureSpex do
      use SexySpex
      use #{conn_case}
      import Phoenix.LiveViewTest

      spex "feature" do
        scenario "user interaction" do
          given_ "page loaded", context do
            {:ok, view, _html} = live(context.conn, "/path")
            {:ok, Map.put(context, :view, view)}
          end

          when_ "user submits form", context do
            html = context.view
              |> form("#form", data: %{field: "value"})
              |> render_submit()
            {:ok, Map.put(context, :html, html)}
          end

          then_ "user sees result", context do
            assert render(context.view) =~ "Success"
            :ok
          end
        end
      end
    end
    ```

    Use plain string paths (`"/path"`), not `~p` sigils.
    """
  end

  defp testing_setup("controller", conn_case, spex_module) do
    """
    ## Controller Testing

    Use `Phoenix.ConnTest`. Test HTTP requests and responses.

    ```elixir
    defmodule #{spex_module}.FeatureSpex do
      use SexySpex
      use #{conn_case}

      spex "feature" do
        scenario "API call" do
          when_ "user makes request", context do
            conn = post(context.conn, "/api/resource", %{name: "Test"})
            {:ok, Map.put(context, :conn, conn)}
          end

          then_ "response is correct", context do
            assert json_response(context.conn, 201)
            :ok
          end
        end
      end
    end
    ```

    Use plain string paths, not `~p` sigils.
    """
  end

  defp testing_setup(_type, _conn_case, _spex_module) do
    """
    ## Testing

    Use standard ExUnit assertions in Given/When/Then steps.
    """
  end

  # ============================================================================
  # Validation (evaluate)
  # ============================================================================

  defp validate_story_specs(scope, story) do
    env = scope.environment
    criteria = story.criteria || []

    errors =
      criteria
      |> Enum.map(fn criterion ->
        spec_path = BddSpecs.spec_file_path(story, criterion)
        {criterion, spec_path, validate_single_spec(env, spec_path)}
      end)
      |> Enum.reject(fn {_, _, result} -> result == :ok end)
      |> Enum.map(fn {criterion, spec_path, {:error, reason}} ->
        "Criterion #{criterion.id} (#{criterion.description}): #{format_error(reason)}\n  Expected: `#{spec_path}`"
      end)

    if Enum.empty?(errors) do
      validate_compilation(scope)
    else
      {:ok, :invalid, "Spec issues:\n\n#{Enum.join(errors, "\n\n")}"}
    end
  end

  defp validate_single_spec(env, spec_path) do
    case Environments.read_file(env, spec_path) do
      {:ok, content} ->
        case Parser.parse(content, spec_path) do
          {:ok, spec} -> validate_spec_content(spec)
          {:error, reason} -> {:error, {:parse_error, reason}}
        end

      _ ->
        {:error, :file_not_found}
    end
  end

  defp validate_spec_content(spec) do
    cond do
      Enum.empty?(spec.scenarios) -> {:error, :no_scenarios}
      not Enum.all?(spec.scenarios, &has_steps?/1) -> {:error, :missing_steps}
      true -> :ok
    end
  end

  defp has_steps?(scenario) do
    not Enum.empty?(scenario.given_steps) or
      not Enum.empty?(scenario.when_steps) or
      not Enum.empty?(scenario.then_steps)
  end

  defp validate_compilation(scope) do
    env = scope.environment

    if env && Environments.file_exists?(env, "mix.exs") do
      case Compile.execute(cwd: env.cwd) do
        %{status: :ok} ->
          {:ok, :valid}

        %{status: :error, data: %{compiler_results: diagnostics}} ->
          feedback = format_compilation_feedback(diagnostics)
          {:ok, :invalid, feedback}
      end
    else
      {:ok, :valid}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp derive_app_name(scope) do
    case scope.environment && Environments.read_file(scope.environment, "mix.exs") do
      {:ok, content} -> extract_app_name(content)
      _ -> "my_app"
    end
  end

  defp extract_app_name(content) do
    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> name
      _ -> "my_app"
    end
  end

  defp camelize(name) do
    name |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end

  defp format_error(:file_not_found), do: "Spec file not found"
  defp format_error(:no_scenarios), do: "Must contain at least one scenario"
  defp format_error(:missing_steps), do: "All scenarios must have Given/When/Then steps"
  defp format_error({:parse_error, reason}), do: "Parse error: #{inspect(reason)}"
  defp format_error(other), do: inspect(other)

  defp format_compilation_feedback(diagnostics) when is_list(diagnostics) do
    errors =
      Enum.map_join(diagnostics, "\n", fn d ->
        file = Map.get(d, :file) || Map.get(d, "file") || "unknown"
        msg = Map.get(d, :message) || Map.get(d, "message") || "unknown"
        pos = Map.get(d, :position) || Map.get(d, "position")
        line = if pos, do: Map.get(pos, :line) || Map.get(pos, "line")
        if line, do: "  #{file}:#{line}: #{msg}", else: "  #{file}: #{msg}"
      end)

    "Compilation failed:\n\n```\n#{errors}\n```"
  end

  defp format_compilation_feedback(output) when is_binary(output) do
    "Compilation failed:\n\n```\n#{output}\n```"
  end

  defp format_compilation_feedback(_), do: "Compilation failed."
end
