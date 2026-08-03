defmodule CodeMySpec.Embeddings.HexDocProjector do
  @moduledoc """
  Projects dependency documentation into the working tree as markdown,
  so the file sync pipeline can embed it.

  Reads `@moduledoc`/`@doc` strings directly from each dependency's
  **source** at `<cwd>/deps/<package>/lib/**/*.ex` and writes them to
  `<cwd>/.code_my_spec/hex_docs/<package>/<module>.md` via
  `Environments.write_file/3` (memfs-friendly in test, real disk in
  production CLI mode).

  ## Why source, not BEAMs

  An earlier version read EEP-48 doc chunks from compiled BEAMs under
  `_build/<env>/lib/<package>/ebin/*.beam` via `Code.fetch_docs/1`. That
  coupled doc extraction to the OTP version baked into the `cms` binary:
  the moment a project's deps were compiled by a newer OTP than the
  binary's bundled runtime, `:beam_lib` would *raise* on the
  unrecognized chunk format and take down the whole sync (`-32603`).

  Source `.ex` files carry the same docs as plain markdown literals and
  are written by `mix deps.get` (tarball unpack) regardless of OTP, so
  parsing them with `Code.string_to_quoted/1` is version-independent by
  construction. The doc strings are already markdown — no rendering, no
  beam loading, no network.

  The projector is idempotent: re-running it against an unchanged
  `deps/` tree produces no observable change in the working tree (writes
  are no-ops at the FileSync layer because fingerprints match). Removed
  packages have their projected directories cleared.
  """

  require Logger

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  @doc """
  Project all installed dependency docs under `scope.cwd`'s `deps/`
  tree into the working tree's `.code_my_spec/hex_docs/` directory.

  Options:
    * `:deps_dir` — relative path under `cwd` to scan, defaults to
      `"deps"`. Exposed for tests.
  """
  def project(%Scope{} = scope, opts \\ []) do
    env = environment(scope)
    deps_rel = Keyword.get(opts, :deps_dir, "deps")

    if dir?(env, deps_rel) do
      do_project(scope, env, deps_rel)
    else
      :ok
    end
  end

  @doc """
  Project a single package's docs.

  Used by the file watcher to react to dependency changes. If the
  package no longer has a `deps/<package>` directory (uninstall), drops
  all projected markdown for that package.

  The user's own app never lives under `deps/`, so scanning `deps/`
  naturally excludes it — no separate "is this a hex dep?" check needed.
  """
  @spec project_package(Scope.t(), String.t(), keyword()) :: :ok
  def project_package(%Scope{} = scope, package, opts \\ []) when is_binary(package) do
    env = environment(scope)
    deps_rel = Keyword.get(opts, :deps_dir, "deps")
    pkg_rel = Path.join(deps_rel, package)

    if dir?(env, pkg_rel) do
      project_package_from_source(scope, env, package, pkg_rel)
    else
      # Package was uninstalled — drop every projected module.
      drop_orphan_modules(scope, package, MapSet.new())
    end
  end

  @doc """
  Project the packages whose recorded version has no docs projected yet.

  This is the convergence step that replaced a settle timer. `Dependencies`
  records what `mix.lock` says the project depends on — which is knowable the
  instant the lock is written, before `mix deps.get` has unpacked anything — and
  this projects the ones whose source has actually landed on disk.

  Returns `%{projected: [name], missing: [name]}`. `missing` is a package the
  lock names whose `deps/<package>` is not there: either still unpacking, or an
  `only:`-gated dependency that will never be fetched in this environment. The
  caller retries a bounded number of times and then reports what stayed missing,
  because those two cases are not distinguishable from here and pretending
  otherwise is how the settle timer went wrong in the first place.

  A package is marked projected only at the version that was actually projected.
  One re-pinned mid-pass stays pending rather than being marked current for a
  version nobody read.
  """
  @spec project_pending(Scope.t(), keyword()) :: %{
          projected: [String.t()],
          missing: [String.t()]
        }
  def project_pending(%Scope{} = scope, opts \\ []) do
    env = environment(scope)
    deps_rel = Keyword.get(opts, :deps_dir, "deps")

    scope
    |> Dependencies.pending()
    |> Enum.reduce(%{projected: [], missing: []}, fn dep, acc ->
      pkg_rel = Path.join(deps_rel, dep.name)

      if dir?(env, pkg_rel) do
        project_package_from_source(scope, env, dep.name, pkg_rel)
        Dependencies.mark_projected(scope, dep.name, dep.version)
        %{acc | projected: [dep.name | acc.projected]}
      else
        %{acc | missing: [dep.name | acc.missing]}
      end
    end)
    |> then(&%{projected: Enum.reverse(&1.projected), missing: Enum.reverse(&1.missing)})
  end

  @doc """
  Drop projected docs for packages the project no longer depends on.

  Keyed on the recorded dependency set rather than on a removal event, so it is
  self-healing: a removal missed while the harness was down is corrected on the
  next pass instead of leaving a package's documentation in the embedding store
  indefinitely, answering questions about a library that is no longer used.

  This is also why the recorded set is more accurate than globbing `deps/`,
  which was the previous source of truth. A directory left behind by a removed
  dependency looks exactly like an installed one; a lock entry cannot be left
  behind, because `mix` rewrites the lock as a whole.
  """
  @spec drop_unrecorded(Scope.t()) :: :ok
  def drop_unrecorded(%Scope{} = scope) do
    recorded =
      scope
      |> Dependencies.list_dependencies()
      |> MapSet.new(& &1.name)

    drop_orphan_packages(scope, recorded)
  end

  @doc """
  Give up on packages that never appeared, recording that they were looked for.

  Called once the retry budget is spent. Marks each at its recorded version so
  the project converges, and drops any docs left over from a previous version.
  The names are returned so the caller can say which packages contributed
  nothing — a package silently missing from the embedding store is the failure
  this whole design exists to make visible.
  """
  @spec settle_missing(Scope.t()) :: [String.t()]
  def settle_missing(%Scope{} = scope) do
    for dep <- Dependencies.pending(scope) do
      drop_orphan_modules(scope, dep.name, MapSet.new())
      Dependencies.mark_projected(scope, dep.name, dep.version)
      dep.name
    end
  end

  # Paths stay relative and the environment resolves them. Joining them onto
  # `scope.cwd` by hand — which is what this did — produces a path that is only
  # meaningful on the machine the scope was built on, so a sprite's deps were
  # looked for on the server's disk and every package read as uninstalled.
  defp environment(%Scope{environment: %Environment{} = env}), do: env
  defp environment(%Scope{cwd: cwd}) when is_binary(cwd), do: Environment.new(:local, cwd)
  defp environment(%Scope{}), do: nil

  # `Environments` has no dir? predicate. A successful listing is the check:
  # `list_directory` on a regular file returns `{:error, :enotdir}`.
  defp dir?(env, path), do: match?({:ok, _}, Environments.list_directory(env, path))

  defp do_project(scope, env, deps_rel) do
    installed = list_packages(env, deps_rel)

    for pkg <- installed do
      project_package_from_source(scope, env, pkg, Path.join(deps_rel, pkg))
    end

    drop_orphan_packages(scope, MapSet.new(installed))

    :ok
  end

  defp list_packages(env, deps_rel) do
    case Environments.list_directory(env, deps_rel) do
      {:ok, names} ->
        Enum.filter(names, &dir?(env, Path.join(deps_rel, &1)))

      _ ->
        []
    end
  end

  defp project_package_from_source(scope, env, pkg, pkg_rel) do
    docs = extract_package_docs(env, pkg_rel)
    write_module_files(scope, pkg, docs)
    drop_orphan_modules(scope, pkg, MapSet.new(Map.keys(docs)))
  end

  # `%{module_name => markdown}` for every Elixir module under the
  # package's `lib/` that carries a `@moduledoc` or at least one `@doc`.
  # Erlang deps (`src/*.erl`) are not parsed — Elixir source only.
  defp extract_package_docs(env, pkg_rel) do
    env
    |> Environments.glob(Path.join(pkg_rel, "lib/**/*.ex"))
    |> Enum.flat_map(&extract_source_docs(env, &1))
    |> Map.new()
  end

  defp extract_source_docs(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        content
        |> extract_modules()
        |> Enum.flat_map(&module_entry/1)

      {:error, _} ->
        []
    end
  end

  # A module is only worth projecting if it actually documents something.
  # A bare module (no `@moduledoc`, no `@doc`) — or `@moduledoc false` —
  # produces nothing, matching the old beam path which skipped modules
  # whose BEAM had no markdown Docs chunk.
  defp module_entry({_name, nil, []}), do: []

  defp module_entry({name, moduledoc, docs}) do
    [{name, render_module(name, moduledoc, docs)}]
  end

  # -- Source doc extraction --

  # Parse a source file and return one entry per `defmodule` found:
  # `{fully_qualified_name, moduledoc_or_nil, [{fun, arity, doc}]}`.
  # Syntactically invalid files yield `[]` rather than raising — a bad
  # dep source must never abort projection (the whole reason we moved
  # off `Code.fetch_docs`).
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

  # -- Write / orphan cleanup (unchanged: operate on the projected tree) --

  defp write_module_files(scope, pkg, docs) do
    Enum.each(docs, &write_module_file(scope, pkg, &1))
  end

  # Skip writes when the on-disk content already matches. Avoids bumping
  # mtime (and firing a downstream watcher event) for idempotent
  # re-projection — e.g., the safety-net stop hook re-running the
  # projector after every sync.
  defp write_module_file(scope, pkg, {mod_name, markdown}) do
    target = Path.join([Paths.hex_docs_dir(), pkg, mod_name <> ".md"])

    if needs_write?(scope, target, markdown) do
      do_write_module_file(scope, target, markdown)
    end
  end

  defp do_write_module_file(scope, target, markdown) do
    case Environments.write_file(scope.environment, target, markdown) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[HexDocProjector] write_file failed for #{target}: #{inspect(reason)}")
    end
  end

  defp needs_write?(scope, target, markdown) do
    case Environments.read_file(scope.environment, target) do
      {:ok, ^markdown} -> false
      _ -> true
    end
  end

  # Walks the existing projected tree and drops any package directory
  # whose package isn't currently installed under `deps/`.
  defp drop_orphan_packages(scope, installed_packages) do
    pattern = Path.join([Paths.hex_docs_dir(), "*", "*.md"])

    scope.environment
    |> Environments.glob(pattern)
    |> Enum.each(&maybe_drop_orphan_path(scope, installed_packages, &1))
  end

  defp maybe_drop_orphan_path(scope, installed_packages, path) do
    case package_from_projected_path(path) do
      nil -> :ok
      pkg -> drop_if_orphan(scope, installed_packages, pkg, path)
    end
  end

  defp drop_if_orphan(scope, installed_packages, pkg, path) do
    unless MapSet.member?(installed_packages, pkg) do
      Environments.delete_file(scope.environment, path)
    end
  end

  # Pulls the package segment out of a projected file path, regardless
  # of whether the path is relative or absolute. The shape we always
  # produce is `<...>/.code_my_spec/hex_docs/<package>/<module>.md`,
  # so we walk the path components looking for the `hex_docs` segment
  # and take the next one.
  defp package_from_projected_path(path) do
    path
    |> Path.split()
    |> Enum.drop_while(&(&1 != "hex_docs"))
    |> Enum.drop(1)
    |> List.first()
  end

  # Drops module markdown files within a package directory whose
  # source module is no longer present in the package's source (i.e.,
  # the package was upgraded and shed a module).
  defp drop_orphan_modules(scope, pkg, current_modules) do
    pattern = Path.join([Paths.hex_docs_dir(), pkg, "*.md"])

    scope.environment
    |> Environments.glob(pattern)
    |> Enum.each(fn path ->
      mod = Path.basename(path, ".md")

      unless MapSet.member?(current_modules, mod) do
        Environments.delete_file(scope.environment, path)
      end
    end)
  end

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
