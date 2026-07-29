defmodule CodeMySpec.Code.ElixirAst do
  @moduledoc """
  Performs AST operations specifically for Elixir source files, extracting module
  dependencies, function definitions with specs, and test assertions. Provides static
  code analysis capabilities by parsing Elixir source files into Abstract Syntax Trees
  and extracting structured metadata.
  """

  @doc """
  Extract module dependencies from an Elixir source file by parsing alias, import,
  and use statements.

  ## Examples

      iex> ElixirAst.get_dependencies("path/to/file.ex")
      {:ok, ["MyApp.User", "Ecto.Query", "GenServer"]}

      iex> ElixirAst.get_dependencies("invalid/path.ex")
      {:error, :enoent}
  """
  @spec get_dependencies(file_path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_dependencies(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, ast} <- Code.string_to_quoted(content) do
      dependencies =
        ast
        |> extract_dependencies([])
        |> Enum.uniq()

      {:ok, dependencies}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extract public function definitions with their @spec declarations from an Elixir
  source file.

  ## Examples

      iex> ElixirAst.get_public_functions("path/to/file.ex")
      {:ok, [%{name: :get_user, arity: 1, spec: "@spec get_user(integer()) :: User.t()"}]}
  """
  @spec get_public_functions(file_path :: String.t()) ::
          {:ok, [%{name: atom(), arity: integer(), spec: String.t() | nil}]} | {:error, term()}
  def get_public_functions(file_path) do
    with {:ok, content} <- File.read(file_path) do
      public_functions_from_source(content)
    end
  end

  @doc """
  Same as `get_public_functions/1`, on source already in hand.

  Parsing is pure; reading is not. Callers that get their bytes from an
  `Environments` environment — anything that might run against a working copy
  on another machine — need the parse without the `File.read`.
  """
  @spec public_functions_from_source(String.t()) ::
          {:ok, [%{name: atom(), arity: integer(), spec: String.t() | nil}]} | {:error, term()}
  def public_functions_from_source(content) do
    with {:ok, ast} <- Code.string_to_quoted(content) do
      functions =
        ast
        |> extract_functions()
        |> deduplicate_functions()

      {:ok, functions}
    end
  end

  @doc """
  Extract test case names and descriptions from an ExUnit test file by parsing test
  and describe blocks.

  ## Examples

      iex> ElixirAst.get_test_assertions("test/my_test.exs")
      {:ok, [%{test_name: "adds two numbers", describe_blocks: [], description: "adds two numbers"}]}

      iex> ElixirAst.get_test_assertions("test/my_test.exs")
      {:ok, [%{test_name: "handles errors", describe_blocks: ["get_user/1 - error cases"], description: "get_user/1 - error cases - handles errors"}]}
  """
  @spec get_test_assertions(file_path :: String.t()) ::
          {:ok,
           [%{test_name: String.t(), describe_blocks: [String.t()], description: String.t()}]}
          | {:error, term()}
  def get_test_assertions(file_path) do
    with {:ok, content} <- File.read(file_path) do
      test_assertions_from_source(content)
    end
  end

  @doc """
  Same as `get_test_assertions/1`, on source already in hand. See
  `public_functions_from_source/1`.
  """
  @spec test_assertions_from_source(String.t()) ::
          {:ok,
           [%{test_name: String.t(), describe_blocks: [String.t()], description: String.t()}]}
          | {:error, term()}
  def test_assertions_from_source(content) do
    with {:ok, ast} <- Code.string_to_quoted(content) do
      {:ok, extract_tests(ast, [])}
    end
  end

  # ============================================================================
  # Private Functions - Dependency Extraction
  # ============================================================================

  defp extract_dependencies({:defmodule, _, [_module_name, [do: body]]}, acc) do
    extract_dependencies(body, acc)
  end

  defp extract_dependencies({:__block__, _, expressions}, acc) do
    Enum.reduce(expressions, acc, &extract_dependencies/2)
  end

  defp extract_dependencies({:alias, _, [module_ast]}, acc) do
    case module_ast do
      {:__aliases__, _, _} = single_alias ->
        [module_name_from_ast(single_alias) | acc]

      {{:., _, [{:__aliases__, _, base_segments}, :{}]}, _, modules} ->
        base = Enum.join(base_segments, ".")

        new_modules =
          Enum.map(modules, fn {:__aliases__, _, segments} ->
            "#{base}.#{Enum.join(segments, ".")}"
          end)

        new_modules ++ acc
    end
  end

  defp extract_dependencies({:alias, _, [module_ast, opts]}, acc) when is_list(opts) do
    module_name = module_name_from_ast(module_ast)
    [module_name | acc]
  end

  defp extract_dependencies({:import, _, [module_ast | _]}, acc) do
    [module_name_from_ast(module_ast) | acc]
  end

  defp extract_dependencies({:use, _, [module_ast | _]}, acc) do
    [module_name_from_ast(module_ast) | acc]
  end

  defp extract_dependencies({_macro, _, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, fn
      arg, inner_acc when is_tuple(arg) -> extract_dependencies(arg, inner_acc)
      [do: block], inner_acc -> extract_dependencies(block, inner_acc)
      _, inner_acc -> inner_acc
    end)
  end

  defp extract_dependencies(_, acc), do: acc

  defp module_name_from_ast({:__aliases__, _, segments}) do
    Enum.join(segments, ".")
  end

  defp module_name_from_ast(atom) when is_atom(atom) do
    Atom.to_string(atom)
  end

  # ============================================================================
  # Private Functions - Function Extraction
  # ============================================================================

  defp extract_functions({:defmodule, _, [_module_name, [do: body]]}) do
    extract_functions_from_block(body, nil)
  end

  defp extract_functions(_ast), do: []

  defp extract_functions_from_block({:__block__, _, expressions}, current_spec) do
    {functions, _} =
      Enum.reduce(expressions, {[], current_spec}, fn expr, {funcs, spec} ->
        case expr do
          {:@, _, [{:spec, _, [spec_ast]}]} ->
            {funcs, spec_to_string(spec_ast)}

          {:def, _, [{func_name, _, args} | _]} when is_atom(func_name) ->
            arity = calculate_arity(args)
            func = %{name: func_name, arity: arity, spec: spec}
            {[func | funcs], nil}

          _ ->
            {funcs, spec}
        end
      end)

    Enum.reverse(functions)
  end

  defp extract_functions_from_block({:def, _, [{func_name, _, args} | _]}, current_spec)
       when is_atom(func_name) do
    arity = calculate_arity(args)
    [%{name: func_name, arity: arity, spec: current_spec}]
  end

  defp extract_functions_from_block(_, _), do: []

  defp calculate_arity(nil), do: 0
  defp calculate_arity(args) when is_list(args), do: length(args)
  defp calculate_arity(_), do: 0

  defp spec_to_string(spec_ast) do
    spec_ast
    |> Macro.to_string()
  end

  defp deduplicate_functions(functions) do
    functions
    |> Enum.group_by(fn f -> {f.name, f.arity} end)
    |> Enum.map(fn {_, funcs} -> hd(funcs) end)
  end

  # ============================================================================
  # Private Functions - Test Extraction
  # ============================================================================

  defp extract_tests({:defmodule, _, [_module_name, [do: body]]}, context) do
    extract_tests(body, context)
  end

  defp extract_tests({:__block__, _, expressions}, context) do
    Enum.flat_map(expressions, &extract_tests(&1, context))
  end

  defp extract_tests({:describe, _, [description, [do: body]]}, context)
       when is_binary(description) do
    new_context = [description | context]
    extract_tests(body, new_context)
  end

  defp extract_tests({:test, _, [test_name | _]}, context) when is_binary(test_name) do
    description = build_test_description(context, test_name)
    describe_blocks = Enum.reverse(context)
    [%{test_name: test_name, describe_blocks: describe_blocks, description: description}]
  end

  defp extract_tests({_macro, _, args}, context) when is_list(args) do
    Enum.flat_map(args, fn
      [do: block] -> extract_tests(block, context)
      arg when is_tuple(arg) -> extract_tests(arg, context)
      _ -> []
    end)
  end

  defp extract_tests(_, _context), do: []

  defp build_test_description([], test_name), do: test_name

  defp build_test_description(context, test_name) do
    context
    |> Enum.reverse()
    |> Enum.join(" - ")
    |> Kernel.<>(" - #{test_name}")
  end
end
