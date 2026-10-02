defmodule CodeMySpec.Embeddings.HexDocParser do
  @moduledoc """
  Parses `@moduledoc`/`@doc` literals out of Elixir source into markdown, one
  document per module. `HexDocReconciler` runs it over a fetched hex tarball's
  `lib/**/*.ex`.

  Source rather than compiled BEAMs: `Code.fetch_docs/1` ties extraction to the
  OTP version that compiled the chunks, and an unrecognised chunk raises. Source
  docs are plain markdown literals, so `Code.string_to_quoted/1` is
  version-independent.
  """

  @doc """
  One `.ex` file's source, parsed into `{module_name, markdown}` pairs.
  """
  @spec docs_from_source(String.t()) :: [{String.t(), String.t()}]
  def docs_from_source(content) when is_binary(content) do
    content
    |> extract_modules()
    |> Enum.flat_map(&module_entry/1)
  end

  # A module is only worth embedding if it actually documents something.
  # A bare module (no `@moduledoc`, no `@doc`) — or `@moduledoc false` —
  # produces nothing.
  defp module_entry({_name, nil, []}), do: []

  defp module_entry({name, moduledoc, docs}) do
    [{name, render_module(name, moduledoc, docs)}]
  end

  # -- Source doc extraction --

  # Parse a source file and return one entry per `defmodule` found:
  # `{fully_qualified_name, moduledoc_or_nil, [{fun, arity, doc}]}`.
  # Syntactically invalid files yield `[]` rather than raising — a bad
  # dep source must never abort a package.
  defp extract_modules(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} -> collect_modules(ast, [])
      {:error, _} -> []
    end
  rescue
    _ -> []
  end

  # `defmodule` carries the doc-bearing body. Record this module, then
  # recurse into its body so nested modules get fully-qualified names.
  defp collect_modules({:defmodule, _, [alias_ast, kw]}, prefix) when is_list(kw) do
    case alias_parts(alias_ast) do
      nil ->
        # Dynamically-named module (e.g. `defmodule unquote(name)`) —
        # can't label it, skip the whole subtree.
        []

      parts ->
        full_parts = prefix ++ parts
        name = Enum.join(full_parts, ".")
        body = Keyword.get(kw, :do)
        {moduledoc, docs} = module_docs(body)
        [{name, moduledoc, docs} | collect_modules(body, full_parts)]
    end
  end

  defp collect_modules({_form, _meta, args}, prefix) when is_list(args) do
    Enum.flat_map(args, &collect_modules(&1, prefix))
  end

  defp collect_modules(list, prefix) when is_list(list) do
    Enum.flat_map(list, &collect_modules(&1, prefix))
  end

  defp collect_modules({left, right}, prefix) do
    collect_modules(left, prefix) ++ collect_modules(right, prefix)
  end

  defp collect_modules(_other, _prefix), do: []

  defp alias_parts({:__aliases__, _, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map(parts, &Atom.to_string/1), else: nil
  end

  defp alias_parts(_), do: nil

  # Walk a module body's top-level statements in order. `@moduledoc`
  # takes the first literal string. `@doc` binds to the next public
  # `def`/`defmacro` (mirroring the compiler). Nested `defmodule` bodies
  # are NOT descended here — their docs belong to the nested module and
  # are picked up by `collect_modules`'s recursion.
  defp module_docs(body) do
    {moduledoc, _pending, docs} =
      body
      |> block_statements()
      |> Enum.reduce({nil, nil, []}, &reduce_statement/2)

    {moduledoc, Enum.reverse(docs)}
  end

  defp reduce_statement({:@, _, [{:moduledoc, _, [doc]}]}, {nil, pending, docs})
       when is_binary(doc),
       do: {doc, pending, docs}

  defp reduce_statement({:@, _, [{:doc, _, [doc]}]}, {moduledoc, _pending, docs})
       when is_binary(doc),
       do: {moduledoc, doc, docs}

  defp reduce_statement({kind, _, [sig | _]}, {moduledoc, pending, docs})
       when kind in [:def, :defmacro] and is_binary(pending) do
    case fun_name_arity(sig) do
      {fun, arity} -> {moduledoc, nil, [{fun, arity, pending} | docs]}
      nil -> {moduledoc, nil, docs}
    end
  end

  # A private def can't carry a doc — drop any pending `@doc`.
  defp reduce_statement({kind, _, _}, {moduledoc, _pending, docs})
       when kind in [:defp, :defmacrop],
       do: {moduledoc, nil, docs}

  defp reduce_statement(_stmt, acc), do: acc

  defp block_statements({:__block__, _, stmts}), do: stmts
  defp block_statements(nil), do: []
  defp block_statements(single), do: [single]

  # Unwrap `def foo(...) when guard` → the call. `def foo` (no parens)
  # is a zero-arity definition.
  defp fun_name_arity({:when, _, [call | _]}), do: fun_name_arity(call)
  defp fun_name_arity({fun, _, args}) when is_atom(fun) and is_list(args), do: {fun, length(args)}
  defp fun_name_arity({fun, _, _}) when is_atom(fun), do: {fun, 0}
  defp fun_name_arity(_), do: nil

  # -- Rendering --

  defp render_module(mod_name, moduledoc, docs) do
    header = "# #{mod_name}\n\n#{moduledoc_text(moduledoc)}\n"

    functions =
      Enum.map_join(docs, "\n", fn {fun, arity, doc} ->
        "## #{fun}/#{arity}\n\n#{String.trim(doc)}\n"
      end)

    String.trim(header <> "\n" <> functions)
  end

  defp moduledoc_text(nil), do: ""
  defp moduledoc_text(text) when is_binary(text), do: String.trim(text)
end
