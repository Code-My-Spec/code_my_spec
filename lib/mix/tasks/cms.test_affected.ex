defmodule Mix.Tasks.Cms.TestAffected do
  @shortdoc "List the test files a diff can affect, independent of what ran last"

  @moduledoc """
  Print the test files a change can affect, computed against a baseline.

      MIX_ENV=test mix cms.test_affected --base origin/main
      MIX_ENV=test mix cms.test_affected --base <sha> --head <sha> --json
      mix test $(MIX_ENV=test mix cms.test_affected --base origin/main)

  Unlike `mix test --stale`, the answer does not depend on what ran last in this
  `_build`: the baseline is a pair of manifests from a run that passed
  (`--manifest-dir`, default this project's own `.mix` directory), and the
  changed files come from `git diff`. See `CodeMySpec.TestImpact`.

  Without `--head` the diff is the working tree against `--base`, untracked
  files included. With it, `git diff <base> <head>`; the tests listed are the
  ones present in the checkout the task runs in.

  ## Options

    * `--base REF` -- the baseline commit (default `HEAD~1`)
    * `--head REF` -- the changed commit (default: the working tree)
    * `--manifest-dir DIR` -- where `compile.elixir` and `compile.test_stale` are
    * `--force-full GLOB` -- a path that runs the whole suite; repeatable,
      replaces the defaults
    * `--strict` -- a changed file nothing in the manifests knows about runs the
      whole suite
    * `--json` -- `%{mode, tests, reasons, why_all, unclassified, seeds}`
    * `--explain` -- on stderr, why each test was chosen

  Plain output is one test file per line. When the whole suite has to run the
  list is every test file, with the reason on stderr; use `--json` to tell the
  two apart.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.TestImpact

  @switches [
    base: :string,
    head: :string,
    manifest_dir: :string,
    force_full: :keep,
    strict: :boolean,
    json: :boolean,
    explain: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Project.get!()

    manifest_dir = opts[:manifest_dir] || Mix.Project.manifest_path()
    tests = test_files()
    changed = changed_files(opts[:base] || "HEAD~1", opts[:head])

    result =
      case TestImpact.read_baseline(manifest_dir) do
        {:ok, baseline} ->
          baseline
          |> Map.merge(%{tests: tests, changed: changed})
          |> TestImpact.select(select_opts(opts))

        {:error, why} ->
          %{
            mode: :all,
            tests: tests,
            reasons: %{},
            why_all: why,
            unclassified: [],
            seeds: []
          }
      end

    report(result, opts)
  end

  defp select_opts(opts) do
    force_full = Keyword.get_values(opts, :force_full)

    [strict: opts[:strict] == true]
    |> then(&if force_full == [], do: &1, else: Keyword.put(&1, :force_full, force_full))
  end

  defp test_files do
    config = Mix.Project.config()
    paths = config[:test_paths] || ["test"]
    pattern = config[:test_pattern] || "*_test.exs"

    Mix.Utils.extract_files(paths, pattern)
  end

  # Added, modified and deleted paths, renames split into both sides so the old
  # module's file seeds as well as the new one.
  defp changed_files(base, nil) do
    tracked = git!(["diff", "--name-only", "--no-renames", base])
    untracked = git!(["ls-files", "--others", "--exclude-standard"])
    Enum.uniq(tracked ++ untracked)
  end

  defp changed_files(base, head), do: git!(["diff", "--name-only", "--no-renames", base, head])

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true)
      {out, status} -> Mix.raise("git #{Enum.join(args, " ")} exited #{status}: #{out}")
    end
  end

  defp report(result, opts) do
    if opts[:explain], do: explain(result)

    cond do
      opts[:json] ->
        IO.puts(JSON.encode!(Map.update!(result, :reasons, &jsonable/1)))

      true ->
        if result.why_all, do: IO.puts(:stderr, "running all tests: #{result.why_all}")
        Enum.each(result.tests, &IO.puts/1)
    end
  end

  defp explain(result) do
    IO.puts(:stderr, "mode: #{result.mode}#{if result.why_all, do: " (#{result.why_all})"}")
    IO.puts(:stderr, "seed modules: #{inspect(result.seeds)}")

    if result.unclassified != [],
      do: IO.puts(:stderr, "unclassified changes: #{Enum.join(result.unclassified, ", ")}")

    for {test, reason} <- Enum.sort(result.reasons),
        do: IO.puts(:stderr, "  #{test}  <- #{describe(reason)}")
  end

  defp describe({:references, module}), do: "references #{inspect(module)}"
  defp describe(reason), do: to_string(reason)

  defp jsonable(reasons), do: Map.new(reasons, fn {test, reason} -> {test, describe(reason)} end)
end
