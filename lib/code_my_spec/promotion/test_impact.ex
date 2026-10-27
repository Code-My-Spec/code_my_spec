defmodule CodeMySpec.Promotion.TestImpact do
  @moduledoc """
  Which test files a diff can affect, without respect to what ran last.

  `mix test --stale` answers "what changed since the last `--stale` run in this
  `_build`", which makes it a fact about one build directory's history rather
  than about a change. This answers the question a promotion gate actually
  has: given a baseline whose tests all passed, and a set of changed files,
  which test files must run?

  It is `Mix.Compilers.Test`'s own selection with the mtimes taken out:

    * the baseline is a pair of manifests from a green run -- the Elixir
      compile manifest (`compile.elixir`, who references whom) and the test
      manifest (`compile.test_stale`, which modules each test file references);
    * the seeds are the modules defined in changed files, instead of modules
      whose `.beam` is newer than the test manifest;
    * the closure over runtime, compile and export references is the same one
      `Mix.Compilers.Test.find_all_dependent_on/4` computes.

  A new reference in the changed tree always starts in a changed file, so the
  baseline's graph is enough for the forward direction: the module that gained
  the edge is already a seed. A removed module is in the baseline manifest, so
  it seeds too.

  Pure: `select/2` takes the manifests' contents and the changed paths and does
  no IO. `Mix.Tasks.Cms.TestAffected` reads the manifests and `git diff`.

  ## What it does not see

  Same blind spots as `--stale`: dynamic dispatch through computed atoms, and
  files read at runtime but not declared `@external_resource`. Those inputs are
  covered by `:force_full` (any changed path matching runs the whole suite),
  and by `unclassified` -- changed non-Elixir files nothing in the manifests
  knows about, reported so a caller can decide, or refused outright with
  `strict: true`.

  The manifest layouts belong to Mix and change between releases. Anything not
  recognised answers `mode: :all`: the cost of an Elixir upgrade is a full run,
  never a missed test.
  """

  require Record
  require Mix.Compilers.Elixir, as: CE

  # `Mix.Compilers.Test`'s private `source` record and `@manifest_vsn`.
  Record.defrecordp(:test_source, :source,
    compile_references: [],
    runtime_references: [],
    external: []
  )

  @test_manifest_vsn 2

  @default_force_full [
    "config/**",
    "mix.exs",
    "mix.lock",
    "priv/repo/**"
  ]

  @type reason ::
          :changed | :new | :external | {:references, module()}

  @type result :: %{
          mode: :partial | :all,
          tests: [Path.t()],
          reasons: %{Path.t() => reason()},
          why_all: String.t() | nil,
          unclassified: [Path.t()],
          seeds: [module()]
        }

  @doc "The paths that always run the whole suite unless `:force_full` overrides them."
  @spec default_force_full() :: [String.t()]
  def default_force_full, do: @default_force_full

  @doc """
  Select the test files `changed` can affect.

  Input:

    * `:modules` / `:sources` -- the contents of the Elixir compile manifest, as
      `Mix.Compilers.Elixir.read_manifest/1` returns them;
    * `:test_sources` -- the test manifest, `%{test_file => record}`;
    * `:tests` -- every test file at the changed tree;
    * `:changed` -- paths added, modified or deleted between the baseline and
      the changed tree, relative to the project root.

  Options: `:force_full` (globs, default `default_force_full/0`) and `:strict`
  (an unclassified changed file runs the whole suite).
  """
  @spec select(map(), keyword()) :: result()
  def select(
        %{
          modules: modules,
          sources: sources,
          test_sources: test_sources,
          tests: tests,
          changed: changed
        },
        opts \\ []
      ) do
    tests = Enum.sort(tests)
    force_full = opts |> Keyword.get(:force_full, @default_force_full) |> Enum.map(&glob_regex/1)
    changed_set = MapSet.new(changed)
    unclassified = unclassified(changed, sources, test_sources, tests)

    cond do
      file = Enum.find(changed, fn file -> Enum.any?(force_full, &Regex.match?(&1, file)) end) ->
        all(tests, unclassified, "#{file} is a force-full path")

      opts[:strict] == true and unclassified != [] ->
        all(tests, unclassified, "unclassified changed file #{hd(unclassified)} (strict)")

      Enum.empty?(sources) or Enum.empty?(test_sources) ->
        all(tests, unclassified, "no usable baseline manifests")

      true ->
        partial(tests, changed_set, unclassified, modules, sources, test_sources)
    end
  end

  defp all(tests, unclassified, why) do
    %{
      mode: :all,
      tests: tests,
      reasons: %{},
      why_all: why,
      unclassified: unclassified,
      seeds: []
    }
  end

  defp partial(tests, changed, unclassified, modules, sources, test_sources) do
    seed_sources = seed_sources(sources, changed)
    seeds = seed_modules(modules, seed_sources)
    affected = closure(MapSet.new(seeds), dependents(sources))

    reasons =
      Enum.reduce(tests, %{}, fn test, acc ->
        case reason(test, Map.fetch(test_sources, test), changed, affected) do
          nil -> acc
          reason -> Map.put(acc, test, reason)
        end
      end)

    %{
      mode: :partial,
      tests: tests |> Enum.filter(&is_map_key(reasons, &1)),
      reasons: reasons,
      why_all: nil,
      unclassified: unclassified,
      seeds: Enum.sort(seeds)
    }
  end

  # A changed Elixir source, or one that declares a changed `@external_resource`.
  defp seed_sources(sources, changed) do
    for {path, CE.source(external: external)} <- sources,
        MapSet.member?(changed, path) or
          Enum.any?(external, &MapSet.member?(changed, external_path(&1))),
        into: MapSet.new(),
        do: path
  end

  # The compile manifest records `{path, mtime_and_size, digest}`; the test
  # manifest records the bare path.
  defp external_path({path, _stat, _digest}), do: path
  defp external_path(path) when is_binary(path), do: path

  # Read from the module records rather than each source's `modules`, so a
  # source deleted since the baseline still names what it defined.
  defp seed_modules(modules, seed_sources) do
    for {module, CE.module(sources: defined_in)} <- modules,
        Enum.any?(defined_in, &MapSet.member?(seed_sources, &1)),
        do: module
  end

  # module => the modules whose source references it any way at all.
  defp dependents(sources) do
    Enum.reduce(sources, %{}, fn {_path,
                                  CE.source(
                                    modules: defined,
                                    runtime_references: runtime,
                                    compile_references: compile,
                                    export_references: export
                                  )},
                                 acc ->
      defined = MapSet.new(defined)

      Enum.reduce(runtime ++ compile ++ export, acc, fn module, acc ->
        Map.update(acc, module, defined, &MapSet.union(&1, defined))
      end)
    end)
  end

  defp closure(seen, dependents), do: expand(seen, seen, dependents)

  defp expand(frontier, seen, dependents) do
    next =
      frontier
      |> Enum.flat_map(&(dependents |> Map.get(&1, MapSet.new()) |> MapSet.to_list()))
      |> MapSet.new()
      |> MapSet.difference(seen)

    if MapSet.size(next) == 0,
      do: seen,
      else: expand(next, MapSet.union(seen, next), dependents)
  end

  defp reason(test, :error, changed, _affected) do
    if MapSet.member?(changed, test), do: :new, else: nil
  end

  defp reason(
         test,
         {:ok,
          test_source(
            runtime_references: runtime,
            compile_references: compile,
            external: external
          )},
         changed,
         affected
       ) do
    cond do
      MapSet.member?(changed, test) ->
        :changed

      module = Enum.find(runtime ++ compile, &MapSet.member?(affected, &1)) ->
        {:references, module}

      Enum.any?(external, &MapSet.member?(changed, &1)) ->
        :external

      true ->
        nil
    end
  end

  # Changed files that are neither Elixir (sources, tests and scripts reach the
  # graph through the manifests or are tests themselves) nor named by any
  # `@external_resource`.
  defp unclassified(changed, sources, test_sources, tests) do
    known =
      Enum.reduce(sources, MapSet.new(tests), fn {path, CE.source(external: external)}, acc ->
        MapSet.union(acc, MapSet.new([path | Enum.map(external, &external_path/1)]))
      end)

    known =
      Enum.reduce(test_sources, known, fn {path, test_source(external: external)}, acc ->
        MapSet.union(acc, MapSet.new([path | external]))
      end)

    changed
    |> Enum.reject(&(Path.extname(&1) in [".ex", ".exs"] or MapSet.member?(known, &1)))
    |> Enum.sort()
  end

  @doc """
  Read the baseline: `{:ok, %{modules:, sources:, test_sources:}}` from a
  `.mix` manifest directory, or `{:error, reason}` for anything missing or from
  a Mix release whose layouts this does not know.
  """
  @spec read_baseline(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read_baseline(manifest_dir) do
    saved = Path.join(manifest_dir, "compile.test_impact")

    if File.exists?(saved) do
      with {:ok, binary} <- File.read(saved),
           %{version: 1, modules: modules, sources: sources, test_sources: tests}
           when is_map(modules) and is_map(sources) and is_map(tests) <- decode(binary) do
        {:ok, %{modules: modules, sources: sources, test_sources: tests}}
      else
        _ -> {:error, "#{saved} is not a recognised green test baseline"}
      end
    else
      elixir_manifest = Path.join(manifest_dir, "compile.elixir")
      test_manifest = Path.join(manifest_dir, "compile.test_stale")

      with {:ok, modules, sources} <- read_elixir_manifest(elixir_manifest),
           {:ok, test_sources} <- read_test_manifest(test_manifest) do
        {:ok, %{modules: modules, sources: sources, test_sources: test_sources}}
      end
    end
  end

  defp read_elixir_manifest(path) do
    {modules, sources} = CE.read_manifest(path)

    if Enum.empty?(sources),
      do:
        {:error, "#{path} is missing or not a manifest layout this Mix release is known to write"},
      else: {:ok, modules, sources}
  end

  defp read_test_manifest(path) do
    with {:ok, binary} <- File.read(path),
         [@test_manifest_vsn | sources] when is_map(sources) <- decode(binary) do
      {:ok, sources}
    else
      _ ->
        {:error,
         "#{path} is missing or not the test manifest layout (version #{@test_manifest_vsn}) this Mix release writes"}
    end
  end

  defp decode(binary) do
    :erlang.binary_to_term(binary)
  rescue
    _ -> :error
  end

  # `**/` is any directories (or none), `**` anything, `*` anything within a
  # path segment.
  defp glob_regex(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.compile!("^" <> pattern <> "$")
  end
end
