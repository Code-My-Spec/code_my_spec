defmodule CodeMySpec.BddSpecs.Parser do
  @moduledoc """
  Parses Spex DSL source files into structured Spec data using Elixir AST analysis.

  Reads spec files, converts to quoted expressions, and walks the AST to extract spex,
  scenario, given_, when_, and then_ macro calls. Returns Spec structs with all scenarios
  and steps populated. Does not execute specs - only extracts structure for analysis and rendering.
  """

  alias CodeMySpec.BddSpecs.Spec
  alias CodeMySpec.BddSpecs.Scenario

  @doc """
  Parse a Spex DSL file into a Spec struct with all scenarios and steps extracted.

  ## Examples

      iex> parse_file("path/to/spec.exs")
      {:ok, %Spec{name: "User authentication", scenarios: [...]}}

      iex> parse_file("nonexistent.exs")
      {:error, :enoent}
  """
  @spec parse_file(String.t()) :: {:ok, Spec.t()} | {:error, term()}
  def parse_file(file_path) do
    with {:ok, content} <- read_file(file_path),
         {:ok, ast} <- parse_content(content),
         {:ok, metadata} <- extract_spec_data(ast) do
      story_id = derive_story_id(file_path)
      criterion_id = derive_criterion_id(file_path)

      # Convert Scenario structs to plain maps for Spec.new
      scenario_maps =
        Enum.map(metadata.scenarios, fn scenario ->
          %{
            name: scenario.name,
            line_number: scenario.line_number,
            given_steps: scenario.given_steps,
            when_steps: scenario.when_steps,
            then_steps: scenario.then_steps,
            tags: scenario.tags
          }
        end)

      spec =
        Spec.new(%{
          name: metadata.name,
          description: metadata.description,
          tags: metadata.tags,
          file_path: file_path,
          story_id: story_id,
          criterion_id: criterion_id,
          scenarios: scenario_maps
        })

      {:ok, spec}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parse a scenario AST node into a Scenario struct with all steps extracted.

  ## Examples

      iex> scenario_ast = quote do
      ...>   scenario "test", context do
      ...>     given_ "precondition", context, do: context
      ...>   end
      ...> end
      iex> parse_scenario(scenario_ast)
      %Scenario{name: "test", given_steps: ["precondition"], when_steps: [], then_steps: []}
  """
  @spec parse_scenario(tuple()) :: Scenario.t()
  def parse_scenario(scenario_ast) do
    {name, line_number} = extract_scenario_name(scenario_ast)
    steps = extract_steps(scenario_ast)

    Scenario.new(%{
      name: name,
      line_number: line_number,
      given_steps: steps.given,
      when_steps: steps.when,
      then_steps: steps.then
    })
  end

  @doc """
  Extract metadata (name, description, tags) from a spex macro call AST.

  ## Examples

      iex> spex_ast = quote do
      ...>   spex "test", description: "desc", tags: [:unit] do
      ...>   end
      ...> end
      iex> extract_spex_metadata(spex_ast)
      %{name: "test", description: "desc", tags: [:unit]}
  """
  @spec extract_spex_metadata(tuple()) :: %{
          name: String.t(),
          description: String.t() | nil,
          tags: [atom()]
        }
  def extract_spex_metadata(spex_ast) do
    case spex_ast do
      {:spex, _, [name | rest]} when is_binary(name) ->
        opts = extract_opts_from_args(rest)

        %{
          name: name,
          description: Keyword.get(opts, :description),
          tags: Keyword.get(opts, :tags, [])
        }

      _ ->
        %{name: "", description: nil, tags: []}
    end
  end

  @doc """
  Validate that a file contains required Spex DSL structure without parsing fully.

  ## Examples

      iex> validate_syntax("path/to/valid_spec.exs")
      :ok

      iex> validate_syntax("path/to/invalid_spec.exs")
      {:error, ["No spex macro found", "No scenarios found"]}
  """
  @spec validate_syntax(String.t()) :: :ok | {:error, [String.t()]}
  def validate_syntax(file_path) do
    errors =
      with {:ok, content} <- read_file(file_path),
           {:ok, ast} <- parse_content(content) do
        validate_structure(ast)
      else
        {:error, :enoent} ->
          ["File not found: #{file_path}"]

        {:error, {_line, _module, reason}} ->
          ["Syntax error: #{inspect(reason)}"]

        {:error, reason} ->
          ["Failed to parse file: #{inspect(reason)}"]
      end

    case errors do
      [] -> :ok
      error_list when is_list(error_list) -> {:error, error_list}
    end
  end

  @doc """
  Extract story ID from file path using naming convention.

  Expects directory names in format: `<story_id>_<description>` or `test_<unique>_<story_id>_<description>`.
  Returns the last numeric ID found before an underscore followed by text.

  ## Examples

      iex> derive_story_id("/path/to/123_user_auth/spec.exs")
      123

      iex> derive_story_id("/path/to/test_999_123_user_auth/spec.exs")
      123

      iex> derive_story_id("/path/to/regular_dir/spec.exs")
      nil
  """
  @spec derive_story_id(String.t()) :: integer() | nil
  def derive_story_id(file_path) do
    dirname = file_path |> Path.dirname() |> Path.basename()

    # Try to match pattern like "test_<unique>_<story_id>_<description>"
    # or "<story_id>_<description>" by finding the last number before underscore+text
    case Regex.scan(~r/(\d+)_(?:[a-z]|$)/, dirname) do
      [] ->
        nil

      matches ->
        # Get the last match (which would be the story_id in test_<unique>_<story_id>_ pattern)
        matches
        |> List.last()
        |> Enum.at(1)
        |> String.to_integer()
    end
  end

  @doc """
  Extract criterion ID from file name using naming convention.

  ## Examples

      iex> derive_criterion_id("/path/to/criterion_123_spex.exs")
      123

      iex> derive_criterion_id("/path/to/regular_spec.exs")
      nil
  """
  @spec derive_criterion_id(String.t()) :: integer() | nil
  def derive_criterion_id(file_path) do
    file_path
    |> Path.basename()
    |> extract_id_from_pattern(~r/^criterion_(\d+)_spex\.exs$/)
  end

  # ============================================================================
  # Private Functions - File I/O
  # ============================================================================

  defp read_file(file_path) do
    File.read(file_path)
  end

  defp parse_content(content) do
    Code.string_to_quoted(content)
  end

  # ============================================================================
  # Private Functions - AST Extraction
  # ============================================================================

  defp extract_spec_data(ast) do
    case find_defmodule(ast) do
      nil ->
        {:error, :no_defmodule}

      module_body ->
        case find_spex_macro(module_body) do
          nil ->
            {:error, :no_spex_macro}

          spex_ast ->
            metadata = extract_spex_metadata(spex_ast)
            scenarios = extract_scenarios(spex_ast)

            {:ok,
             %{
               name: metadata.name,
               description: metadata.description,
               tags: metadata.tags,
               scenarios: scenarios
             }}
        end
    end
  end

  defp find_defmodule({:defmodule, _, [_module_name, [do: body]]}) do
    body
  end

  defp find_defmodule(_), do: nil

  defp find_spex_macro({:__block__, _, expressions}) do
    Enum.find_value(expressions, fn expr ->
      case expr do
        {:spex, _, _} -> expr
        _ -> nil
      end
    end)
  end

  defp find_spex_macro({:spex, _, _} = spex_ast), do: spex_ast
  defp find_spex_macro(_), do: nil

  defp extract_scenarios(spex_ast) do
    case spex_ast do
      {:spex, _, args} ->
        args
        |> find_do_block()
        |> extract_scenario_list()
        |> Enum.map(&parse_scenario/1)

      _ ->
        []
    end
  end

  defp find_do_block(args) do
    Enum.find_value(args, fn
      [do: block] -> block
      _ -> nil
    end)
  end

  defp extract_scenario_list(nil), do: []

  defp extract_scenario_list({:__block__, _, expressions}) do
    Enum.filter(expressions, fn
      {:scenario, _, _} -> true
      _ -> false
    end)
  end

  defp extract_scenario_list({:scenario, _, _} = scenario), do: [scenario]
  defp extract_scenario_list(_), do: []

  defp extract_scenario_name({:scenario, meta, [name | _]}) when is_binary(name) do
    line_number = Keyword.get(meta, :line)
    {name, line_number}
  end

  defp extract_scenario_name(_), do: {"", nil}

  defp extract_steps(scenario_ast) do
    case scenario_ast do
      {:scenario, _, args} ->
        args
        |> find_do_block()
        |> collect_steps(%{given: [], when: [], then: []})

      _ ->
        %{given: [], when: [], then: []}
    end
  end

  defp collect_steps(nil, acc), do: acc

  defp collect_steps({:__block__, _, expressions}, acc) do
    Enum.reduce(expressions, acc, &collect_step/2)
  end

  defp collect_steps(expr, acc) do
    collect_step(expr, acc)
  end

  defp collect_step({:given_, _, [description | _]}, acc) when is_binary(description) do
    %{acc | given: acc.given ++ [description]}
  end

  defp collect_step({:when_, _, [description | _]}, acc) when is_binary(description) do
    %{acc | when: acc.when ++ [description]}
  end

  defp collect_step({:then_, _, [description | _]}, acc) when is_binary(description) do
    %{acc | then: acc.then ++ [description]}
  end

  defp collect_step(_, acc), do: acc

  defp extract_opts_from_args(args) do
    Enum.find_value(args, [], fn
      opts when is_list(opts) -> opts
      [do: _block] -> []
      _ -> []
    end)
  end

  # ============================================================================
  # Private Functions - Validation
  # ============================================================================

  defp validate_structure(ast) do
    []
    |> validate_has_defmodule(ast)
    |> validate_has_spex(ast)
    |> validate_has_scenarios(ast)
  end

  defp validate_has_defmodule(errors, ast) do
    case find_defmodule(ast) do
      nil -> errors ++ ["No defmodule declaration found"]
      _ -> errors
    end
  end

  defp validate_has_spex(errors, ast) do
    case find_defmodule(ast) do
      nil ->
        errors

      module_body ->
        case find_spex_macro(module_body) do
          nil -> errors ++ ["No spex macro found"]
          _ -> errors
        end
    end
  end

  defp validate_has_scenarios(errors, ast) do
    case find_defmodule(ast) do
      nil ->
        errors

      module_body ->
        case find_spex_macro(module_body) do
          nil ->
            errors

          spex_ast ->
            scenarios = extract_scenarios(spex_ast)

            if Enum.empty?(scenarios) do
              errors ++ ["No scenarios found in spex"]
            else
              errors
            end
        end
    end
  end

  # ============================================================================
  # Private Functions - ID Extraction
  # ============================================================================

  defp extract_id_from_pattern(string, regex) do
    case Regex.run(regex, string) do
      [_, id_string] -> String.to_integer(id_string)
      _ -> nil
    end
  end
end
