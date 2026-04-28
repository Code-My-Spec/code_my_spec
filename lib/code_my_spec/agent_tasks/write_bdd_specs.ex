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

  defp build_prompt(story, component, app_name, _app_module, spex_module) do
    criteria = story.criteria || []
    component_type = component.type

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

    #{testing_setup(component_type, spex_module)}

    ## Spex DSL Quick Reference

    Every spec file uses `#{spex_module}.Case` as its base — that case
    template wires up `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, the
    SexySpex DSL, and the DB sandbox. Never reach for
    `<App>Web.ConnCase` directly; always go through `#{spex_module}.Case`.

    ```elixir
    defmodule #{spex_module}.FeatureNameSpex do
      use #{spex_module}.Case

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
    - Case template: `test/support/#{app_name}_spex_case.ex` — defines `#{spex_module}.Case`
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

  defp testing_setup("liveview", spex_module) do
    """
    ## LiveView Testing

    `#{spex_module}.Case` already imports `Phoenix.LiveViewTest`. Test what users SEE and DO.

    ```elixir
    defmodule #{spex_module}.FeatureSpex do
      use #{spex_module}.Case

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

  defp testing_setup("controller", spex_module) do
    """
    ## Controller Testing

    `#{spex_module}.Case` already imports `Phoenix.ConnTest`. Test HTTP requests and responses.

    ```elixir
    defmodule #{spex_module}.FeatureSpex do
      use #{spex_module}.Case

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

  defp testing_setup(_type, spex_module) do
    """
    ## Testing

    `#{spex_module}.Case` provides the SexySpex DSL plus standard ExUnit
    assertions. Drive the component's real interaction surface from
    Given/When/Then steps; never call context functions directly.

    ```elixir
    defmodule #{spex_module}.FeatureSpex do
      use #{spex_module}.Case

      spex "feature" do
        scenario "behavior" do
          given_ "setup", context do
            {:ok, context}
          end

          when_ "action through the real surface", context do
            {:ok, context}
          end

          then_ "outcome is observable through the same surface", context do
            assert true
            :ok
          end
        end
      end
    end
    ```
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
        "Criterion #{criterion.id} (#{criterion.description}): #{format_error(reason, spec_path)}\n  Expected: `#{spec_path}`"
      end)

    if Enum.empty?(errors) do
      {:ok, :valid}
    else
      {:ok, :invalid, "Spec issues:\n\n#{Enum.join(errors, "\n\n")}"}
    end
  end

  defp format_error(reason, spec_path) do
    case reason do
      :file_not_found ->
        "Spec file not found"

      :no_scenarios ->
        "Must contain at least one scenario"

      :missing_steps ->
        "All scenarios must have Given/When/Then steps"

      :missing_spex_case ->
        "Spec must `use <App>Spex.Case` as the base case template " <>
          "(provides SexySpex DSL + Phoenix.ConnTest + Phoenix.LiveViewTest + DB sandbox). " <>
          "Do not `use <App>Web.ConnCase` directly from a spec."

      {:syntax_error, %{line: line, message: msg}} when is_integer(line) ->
        "Compilation failed:\n  #{spec_path}:#{line}: #{msg}"

      {:syntax_error, %{message: msg}} ->
        "Compilation failed:\n  #{spec_path}: #{msg}"

      {:parse_error, parse_reason} ->
        "Parse error: #{inspect(parse_reason)}"

      other ->
        inspect(other)
    end
  end

  defp validate_single_spec(env, spec_path) do
    case Environments.read_file(env, spec_path) do
      {:ok, content} ->
        with :ok <- validate_compiles(content, spec_path),
             {:ok, spec} <- safe_parse(content, spec_path),
             :ok <- validate_uses_spex_case(content) do
          validate_spec_content(spec)
        end

      _ ->
        {:error, :file_not_found}
    end
  end

  # Compile each spec file in-process via `Code.string_to_quoted/2` —
  # cheap, deterministic, and operates on the in-memory string rather
  # than shelling out to `mix compile`. Catches syntax errors with
  # `{file, line}` location info; semantic issues like undefined
  # macros are caught by `validate_uses_spex_case/1` instead.
  defp validate_compiles(content, spec_path) do
    case Code.string_to_quoted(content, file: spec_path) do
      {:ok, _ast} ->
        :ok

      {:error, {meta, msg, token}} ->
        line = line_from_meta(meta)
        message = format_string_to_quoted_message(msg, token)
        {:error, {:syntax_error, %{line: line, message: message}}}
    end
  end

  defp safe_parse(content, spec_path) do
    case Parser.parse(content, spec_path) do
      {:ok, spec} -> {:ok, spec}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp line_from_meta(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_from_meta(line) when is_integer(line), do: line
  defp line_from_meta(_), do: nil

  defp format_string_to_quoted_message({header, body}, token)
       when is_binary(header) and is_binary(body) do
    "#{header}#{body}#{token}"
  end

  defp format_string_to_quoted_message(msg, token) when is_binary(msg) do
    "#{msg}#{token}"
  end

  defp format_string_to_quoted_message(msg, _token), do: inspect(msg)

  # The `spex/scenario/given_/when_/then_` macros only resolve when the
  # spec module pulls in SexySpex. The project's colocated case template
  # `<App>Spex.Case` does that — and also wires up ConnTest, LiveViewTest,
  # and the DB sandbox. A spec that reaches for `<App>Web.ConnCase` (or
  # `use SexySpex` directly) would compile in isolation but breaks the
  # established pattern, so reject it at validation time rather than
  # surface a confusing macro error at run time.
  #
  # AST walk (rather than a textual regex) so a comment that mentions
  # `<App>Spex.Case` doesn't satisfy the check by accident.
  defp validate_uses_spex_case(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        if uses_spex_case?(ast),
          do: :ok,
          else: {:error, :missing_spex_case}

      {:error, _} ->
        # Code couldn't even parse it — let the Spex parser surface
        # the parse error in its own pass.
        :ok
    end
  end

  defp uses_spex_case?(ast) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:use, _, [{:__aliases__, _, parts} | _]} -> spex_case_alias?(parts)
      _ -> false
    end)
  end

  defp spex_case_alias?(parts) when is_list(parts) and length(parts) >= 2 do
    parts
    |> Enum.map_join(".", &Atom.to_string/1)
    |> String.match?(~r/Spex\.Case$/)
  end

  defp spex_case_alias?(_), do: false

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
end
