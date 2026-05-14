defmodule CodeMySpec.Embeddings.HexDocProjector do
  @moduledoc """
  Projects EEP-48 documentation from compiled BEAM files into the
  working tree as markdown, so the file sync pipeline can embed it.

  Reads from `<cwd>/_build/<env>/lib/<package>/ebin/*.beam` (real
  disk — BEAMs aren't a memfs concept) and writes to
  `<cwd>/.code_my_spec/hex_docs/<package>/<module>.md` via
  `Environments.write_file/3` (memfs-friendly in test, real disk in
  production CLI mode).

  The projector is idempotent: re-running it against an unchanged
  `_build/` produces no observable change in the working tree
  (writes are no-ops at the FileSync layer because fingerprints
  match). Removed packages have their projected directories cleared.
  """

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  @doc """
  Project all installed hex docs under `scope.cwd`'s `_build/` tree
  into the working tree's `.code_my_spec/hex_docs/` directory.

  Options:
    * `:build_dir` — relative path under `cwd` to scan, defaults to
      `"_build/dev/lib"`. Spex pass `"_build/test/lib"`.
  """
  def project(%Scope{} = scope, opts \\ []) do
    cwd = scope.cwd || scope.environment.cwd
    build_rel = Keyword.get(opts, :build_dir, "_build/dev/lib")
    build_dir = Path.join(cwd, build_rel)

    if File.dir?(build_dir) do
      do_project(scope, build_dir)
    else
      :ok
    end
  end

  @doc """
  Project a single package's hex docs.

  Used by the file watcher to react to changes under
  `_build/<env>/lib/<package>/ebin/`. If the package no longer has
  an `ebin` directory (uninstall), drops all projected markdown for
  that package.

  Skips packages that aren't hex deps (i.e., the project's own app)
  to avoid spamming the working tree with the user's own module
  docs every time their BEAMs are recompiled.
  """
  @spec project_package(Scope.t(), String.t(), keyword()) :: :ok
  def project_package(%Scope{} = scope, package, opts \\ []) when is_binary(package) do
    cwd = scope.cwd || scope.environment.cwd

    if hex_dep?(cwd, package) do
      build_rel = Keyword.get(opts, :build_dir, "_build/dev/lib")
      ebin_dir = Path.join([cwd, build_rel, package, "ebin"])

      if File.dir?(ebin_dir) do
        project_package_from_ebin(scope, package, ebin_dir)
      else
        # Package was uninstalled — drop every projected module.
        drop_orphan_modules(scope, package, MapSet.new())
      end
    else
      :ok

        :ok
    end
  end

  # A real hex dep has an unpacked source tree at `<cwd>/deps/<package>`.
  # The user's own project compiles to `_build/<env>/lib/<app_name>` but
  # has no corresponding `deps/<app_name>` directory — that's how we
  # tell them apart without parsing mix.exs.
  defp hex_dep?(cwd, package) do
    File.dir?(Path.join([cwd, "deps", package]))
  end

  defp do_project(scope, build_dir) do
    cwd = scope.cwd || scope.environment.cwd

    installed =
      build_dir
      |> list_packages()
      |> Enum.filter(fn {pkg, _ebin} -> hex_dep?(cwd, pkg) end)
      |> Map.new()

    for {pkg, ebin_dir} <- installed do
      project_package_from_ebin(scope, pkg, ebin_dir)
    end

    drop_orphan_packages(scope, MapSet.new(Map.keys(installed)))

    :ok
  end

  defp list_packages(build_dir) do
    case File.ls(build_dir) do
      {:ok, names} ->
        names
        |> Enum.map(fn name -> {name, Path.join([build_dir, name, "ebin"])} end)
        |> Enum.filter(fn {_name, ebin} -> File.dir?(ebin) end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp project_package_from_ebin(scope, pkg, ebin_dir) do
    docs = extract_package_docs(ebin_dir)
    write_module_files(scope, pkg, docs)
    drop_orphan_modules(scope, pkg, MapSet.new(Map.keys(docs)))
  end

  defp extract_package_docs(ebin_dir) do
    ebin_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(&extract_beam_docs/1)
    |> Map.new()
  end

  defp extract_beam_docs(beam_path) do
    case Code.fetch_docs(beam_path) do
      {:docs_v1, _anno, _lang, "text/markdown", mod_doc, _meta, func_docs} ->
        mod_name = beam_path |> Path.basename(".beam") |> strip_elixir_prefix()
        markdown = render_module(mod_name, mod_doc, func_docs)
        if markdown == "", do: [], else: [{mod_name, markdown}]

      _ ->
        []
    end
  end

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(other), do: other

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
      Logger.info("[ProjectorDecision] write pkg=#{pkg} mod=#{mod_name} bytes=#{byte_size(markdown)}")
      do_write_module_file(scope, target, markdown)
    else
      Logger.info("[ProjectorDecision] skip pkg=#{pkg} mod=#{mod_name} (content unchanged)")
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
  # whose package isn't currently installed in `_build/`.
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
  # source module is no longer present in the package's BEAMs (i.e.,
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

  # -- Rendering (lifted from DocExtractor; same shape) --

  defp render_module(mod_name, mod_doc, func_docs) do
    header = "# #{mod_name}\n\n#{extract_text(mod_doc)}\n"

    functions =
      func_docs
      |> Enum.filter(fn {_id, _anno, _sigs, doc, _meta} -> has_doc?(doc) end)
      |> Enum.map_join("\n", fn {{_kind, name, arity}, _anno, signatures, doc, _meta} ->
        sig = format_signature(name, arity, signatures)
        "## #{sig}\n\n#{extract_text(doc)}\n"
      end)

    String.trim(header <> "\n" <> functions)
  end

  defp extract_text(%{"en" => text}), do: String.trim(text)
  defp extract_text(_), do: ""

  defp has_doc?(%{"en" => _}), do: true
  defp has_doc?(_), do: false

  defp format_signature(_name, _arity, [sig | _]) when is_binary(sig), do: sig
  defp format_signature(name, arity, _), do: "#{name}/#{arity}"
end
