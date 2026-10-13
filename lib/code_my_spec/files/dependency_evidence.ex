defmodule CodeMySpec.Files.DependencyEvidence do
  @moduledoc """
  Extract conservative, static module dependency evidence from Elixir source.

  This module only parses and inspects quoted syntax. It never evaluates or
  compiles the source being inspected.
  """

  @version 2

  @spec extract(binary()) :: map()
  def extract(source) when is_binary(source) do
    hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        state = %{
          refs: MapSet.new(),
          unresolved: MapSet.new(),
          modules: MapSet.new(),
          boundaries: MapSet.new()
        }

        {_aliases, evidence} = walk(ast, nil, %{}, state)

        %{
          "version" => @version,
          "status" => "ok",
          "source_hash" => hash,
          "modules" => evidence.modules |> Enum.sort(),
          "references" => sorted_refs(evidence.refs),
          "unresolved" => sorted_unresolved(evidence.unresolved),
          "boundaries" => Enum.sort_by(evidence.boundaries, & &1["module"])
        }

      {:error, {location, error, token}} ->
        %{
          "version" => @version,
          "status" => "error",
          "source_hash" => hash,
          "modules" => [],
          "references" => [],
          "unresolved" => [],
          "boundaries" => [],
          "parse_error" => %{
            "line" => location[:line] || 1,
            "column" => location[:column],
            "message" => error_message(error) <> token_string(token)
          }
        }
    end
  end

  defp token_string(nil), do: ""
  defp token_string(token) when is_binary(token), do: " near #{inspect(token)}"
  defp token_string(_), do: ""
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  # Each walk returns its lexical aliases and an explicit evidence accumulator.
  defp walk({:defmodule, meta, [name_ast, body]}, current, aliases, state) do
    name = module_name(name_ast, current, aliases)

    if is_nil(name) do
      source = current || "__top_level__"
      {aliases, add_unresolved(state, source, line(meta), "dynamic_module_definition")}
    else
      name =
        if current && not String.contains?(name, "."),
          do: current <> "." <> name,
          else: name

      child_aliases = aliases
      state = %{state | modules: MapSet.put(state.modules, name)}
      {_child_aliases, state} = walk(body, name, child_aliases, state)
      child_alias = name |> String.split(".") |> List.last()
      {Map.put(aliases, child_alias, name), state}
    end
  end

  defp walk({name, _, args}, current, aliases, state)
       when name in [:if, :unless, :case, :cond, :with, :for, :receive, :try] and is_list(args) do
    {_, state} = walk_scoped(args, current, aliases, state)
    {aliases, state}
  end

  defp walk({:fn, _, clauses}, current, aliases, state) do
    {_, state} = walk_scoped(clauses, current, aliases, state)
    {aliases, state}
  end

  defp walk({:->, _, [patterns, body]}, current, aliases, state) do
    {_, state} = walk(patterns, current, aliases, state)
    {_branch_aliases, state} = walk(body, current, aliases, state)
    {aliases, state}
  end

  defp walk({:quote, _, _}, _current, aliases, state), do: {aliases, state}

  defp walk({:@, _, [{name, _, _}]}, _current, aliases, state)
       when name in [:spec, :type, :typep, :callback, :macrocallback, :doc, :moduledoc],
       do: {aliases, state}

  defp walk({:__block__, _, expressions}, current, aliases, state) do
    Enum.reduce(expressions, {aliases, state}, fn expression, {env, acc} ->
      walk(expression, current, env, acc)
    end)
  end

  defp walk({:alias, _, [{{:., _, [prefix, :{}]}, _, members}]}, current, aliases, state) do
    base = resolve_module(prefix, current, aliases)

    env =
      Enum.reduce(members, aliases, fn member, acc ->
        suffix = module_name(member, nil, %{})
        if base && suffix, do: Map.put(acc, suffix, base <> "." <> suffix), else: acc
      end)

    {env, state}
  end

  defp walk({:alias, _, args}, current, aliases, state) do
    env =
      case alias_binding(args, current, aliases) do
        nil -> aliases
        {key, value} -> Map.put(aliases, key, value)
      end

    {env, state}
  end

  defp walk({kind, meta, args}, current, aliases, state)
       when kind in [:use, :import, :require] do
    state = record_target(kind, args, meta, current, aliases, state)
    state = record_boundary(kind, args, current, aliases, state)
    {_, state} = walk_children(args, current, aliases, state)
    {aliases, state}
  end

  defp walk({:%, meta, [target, fields]}, current, aliases, state) do
    state =
      case resolve_module(target, current, aliases) do
        nil -> add_unresolved(state, current, line(meta), "dynamic_struct")
        ^current -> state
        resolved -> add_ref(state, current, resolved, "struct", line(meta))
      end

    {_, state} = walk(fields, current, aliases, state)
    {aliases, state}
  end

  # `copy.root`: field access on a value, written without parentheses. Read as
  # a dynamic module call it marked 899 of 1,309 files uncertain, and an
  # uncertain file's stale edges are never retracted (2026-10-12).
  defp walk({{:., _, [target, field]}, meta, []}, current, aliases, state)
       when is_atom(field) and not is_atom(target) and
              elem(target, 0) not in [:__aliases__, :__MODULE__] do
    if Keyword.get(meta, :no_parens, false) do
      walk(target, current, aliases, state)
    else
      {aliases, add_unresolved(state, current, line(meta), "dynamic_module_call")}
    end
  end

  defp walk({{:., _, [target, function]}, meta, args}, current, aliases, state)
       when is_atom(function) and is_list(args) do
    state =
      case resolve_module(target, current, aliases) do
        nil -> add_unresolved(state, current, line(meta), "dynamic_module_call")
        ^current -> state
        resolved -> add_ref(state, current, resolved, "call", line(meta))
      end

    {_, state} = walk_children(args, current, aliases, state)
    {aliases, state}
  end

  defp walk(
         {:&, _, [{:/, _, [{{:., _, [target, function]}, meta, _}, arity]}]},
         current,
         aliases,
         state
       )
       when is_atom(function) and is_integer(arity) do
    state =
      case resolve_module(target, current, aliases) do
        nil -> add_unresolved(state, current, line(meta), "dynamic_module_capture")
        ^current -> state
        resolved -> add_ref(state, current, resolved, "call", line(meta))
      end

    {aliases, state}
  end

  defp walk({name, _meta, args}, current, aliases, state)
       when name in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp] and is_list(args) do
    # Function heads contain patterns and guard syntax; visit only the body.
    state = walk_function_head(List.first(args), current, aliases, state)
    state = walk_function_bodies(List.last(args), current, aliases, state)

    {aliases, state}
  end

  defp walk({:apply, meta, args}, current, aliases, state)
       when is_list(args) and length(args) == 3 do
    [target, function, _arguments] = args

    state =
      if is_atom(function) do
        case resolve_module(target, current, aliases) do
          nil -> add_unresolved(state, current, line(meta), "dynamic_apply")
          ^current -> state
          resolved -> add_ref(state, current, resolved, "call", line(meta))
        end
      else
        add_unresolved(state, current, line(meta), "dynamic_apply")
      end

    {_, state} = walk_children(args, current, aliases, state)
    {aliases, state}
  end

  defp walk({:__aliases__, _, _}, _current, aliases, state), do: {aliases, state}

  # An unqualified call after `import` reaches the imported module (already a
  # reference, from the import itself), a local function or Kernel; none is an
  # edge the import did not record, so it marks nothing uncertain.

  defp walk(list, current, aliases, state) when is_list(list),
    do:
      if(keyword_pairs?(list),
        do: walk_scoped(Keyword.values(list), current, aliases, state),
        else: walk_children(list, current, aliases, state)
      )

  defp walk(tuple, current, aliases, state) when is_tuple(tuple),
    do: walk_children(Tuple.to_list(tuple), current, aliases, state)

  defp walk(_, _current, aliases, state), do: {aliases, state}

  defp walk_children(children, current, aliases, state) do
    Enum.reduce(children, {aliases, state}, fn child, {env, acc} ->
      walk(child, current, env, acc)
    end)
  end

  defp walk_scoped(children, current, aliases, state) do
    state =
      Enum.reduce(children, state, fn child, acc ->
        {_local_aliases, acc} = walk(child, current, aliases, acc)
        acc
      end)

    {aliases, state}
  end

  defp walk_function_head({:when, _, [call, guard]}, current, aliases, state) do
    state = walk_function_head(call, current, aliases, state)
    {_aliases, state} = walk(guard, current, aliases, state)
    state
  end

  defp walk_function_head({name, _, args}, current, aliases, state)
       when is_atom(name) and is_list(args),
       do: elem(walk_children(args, current, aliases, state), 1)

  defp walk_function_head(_, _, _, state), do: state

  defp walk_function_bodies(clauses, current, aliases, state) when is_list(clauses) do
    Enum.reduce(clauses, state, fn
      {kind, body}, acc when kind in [:do, :rescue, :catch, :after, :else] ->
        {_local_aliases, acc} = walk(body, current, aliases, acc)
        acc

      _, acc ->
        acc
    end)
  end

  defp walk_function_bodies(_, _, _, state), do: state

  defp keyword_pairs?([]), do: false
  defp keyword_pairs?(list), do: Enum.all?(list, &match?({key, _} when is_atom(key), &1))

  defp record_target(kind, [target | _], meta, current, aliases, state) do
    case resolve_module(target, current, aliases) do
      nil -> add_unresolved(state, current, line(meta), "dynamic_#{kind}")
      resolved -> add_ref(state, current, resolved, "macro", line(meta))
    end
  end

  defp record_target(_, _, _, _, _, state), do: state

  # A module's `use Boundary` declaration, as data: which modules are boundaries
  # is the architecture the compiler enforces, and the graph of it is drawn
  # from these. `deps` are not read — the edges come from what the code calls.
  defp record_boundary(:use, [target | rest], current, aliases, state) when is_binary(current) do
    case resolve_module(target, current, aliases) do
      "Boundary" ->
        opts = boundary_opts(rest)

        declaration = %{
          "module" => current,
          "top_level" => Keyword.get(opts, :top_level?) == true,
          "classify_to" => resolve_module(Keyword.get(opts, :classify_to), current, aliases)
        }

        %{state | boundaries: MapSet.put(state.boundaries, declaration)}

      _ ->
        state
    end
  end

  defp record_boundary(_, _, _, _, state), do: state

  defp boundary_opts([opts]) when is_list(opts),
    do: Enum.filter(opts, &match?({key, _} when is_atom(key), &1))

  defp boundary_opts(_), do: []

  defp alias_binding([target | opts], current, aliases) do
    resolved = resolve_module(target, current, aliases)

    if resolved do
      opts =
        case opts do
          [keyword] when is_list(keyword) -> keyword
          keyword when is_list(keyword) -> keyword
          _ -> []
        end

      as = Keyword.get(opts, :as)
      key = if as, do: module_name(as, nil, %{}), else: List.last(String.split(resolved, "."))
      {key, resolved}
    end
  end

  defp alias_binding(_, _, _), do: nil

  defp resolve_module({:__aliases__, _, parts}, current, aliases) do
    case parts do
      [{:__MODULE__, _, _} | rest] ->
        join_module(current, rest)

      [:__MODULE__ | rest] ->
        join_module(current, rest)

      _ ->
        parts = Enum.map(parts, &part_name/1)
        [first | rest] = parts

        cond do
          first == "Elixir" -> Enum.join(rest, ".")
          Map.has_key?(aliases, first) -> Enum.join([aliases[first] | rest], ".")
          true -> Enum.join(parts, ".")
        end
    end
  end

  defp resolve_module({:__MODULE__, _, _}, current, _aliases), do: current
  # A module written as a literal atom is static, not dynamic: string
  # interpolation expands to `Kernel.to_string/1` with `Kernel` as the atom
  # `:"Elixir.Kernel"`, and an Erlang call names `:ets`. Calling these dynamic
  # marked 997 of 1,302 files uncertain, which kept every stale edge out of
  # them alive (2026-10-12).
  defp resolve_module(atom, _current, _aliases) when atom in [nil, true, false], do: nil

  defp resolve_module(atom, _current, _aliases) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> name
      name -> ":" <> name
    end
  end

  defp resolve_module(_, _, _), do: nil

  defp module_name(ast, current, aliases), do: resolve_module(ast, current, aliases)
  defp part_name(part) when is_atom(part), do: Atom.to_string(part)
  defp part_name({:__MODULE__, _, _}), do: "__MODULE__"
  defp part_name(_), do: ""
  defp join_module(nil, _parts), do: nil
  defp join_module(current, []), do: current
  defp join_module(current, parts), do: Enum.join([current | Enum.map(parts, &part_name/1)], ".")
  defp line(meta), do: Keyword.get(meta, :line, 1)

  defp add_ref(state, nil, _target, _kind, _line), do: state
  defp add_ref(state, source, source, _kind, _line), do: state

  defp add_ref(state, source, target, kind, line) do
    %{
      state
      | refs:
          MapSet.put(state.refs, %{
            "source" => source,
            "target" => target,
            "kind" => kind,
            "line" => line
          })
    }
  end

  defp add_unresolved(state, nil, _line, _reason), do: state

  defp add_unresolved(state, source, line, reason) do
    %{
      state
      | unresolved:
          MapSet.put(state.unresolved, %{"source" => source, "line" => line, "reason" => reason})
    }
  end

  defp sorted_refs(refs),
    do: Enum.sort_by(refs, &{&1["source"], &1["target"], &1["kind"], &1["line"]})

  defp sorted_unresolved(items),
    do: Enum.sort_by(items, &{&1["source"], &1["line"], &1["reason"]})
end
