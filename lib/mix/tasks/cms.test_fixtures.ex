defmodule Mix.Tasks.Cms.TestFixtures do
  @shortdoc "Clone the fixture repositories and record analyzer output"

  @moduledoc """
  Populates the test fixtures that the suite reads and no longer generates.

      MIX_ENV=test mix cms.test_fixtures

  Two things come out of it:

  * `test/fixtures/analyzer_output/` — recorded compiler, ExUnit and spex output
    in the shape the analyzers emit. Committed, about 60KB, read directly by
    tests.
  * `../code_my_spec_test_repos/` — the real Phoenix projects the analyzer tests
    run against. 9MB with a build tree, so not committable; only the five
    analyzer tests need it.

  ## Why this is a task rather than test setup

  It used to run from `test_helper.exs` on every `mix test`. Most of it was
  `File.exists?`-guarded and cheap, but `ensure_repo_fresh/2` was not: it ran
  `git pull` in both fixture repositories every single time. Those repositories
  live under a path every worktree reaches through a symlink to one shared
  directory, so two agents starting suites near each other were two pulls racing
  in one repository before a test had run — and the analyzer tests then compiled
  and ran suites inside that same shared build tree.

  That is the contention behind the `** (EXIT from #PID<…>) killed` findings
  that block the stop hook: a suite terminated rather than failing, naming
  different tests each run, every one passing alone. Two agents diagnosed it for
  an afternoon without being able to see each other's load.

  Run this when the recorded output should change — a new Elixir, a credo
  upgrade, a deliberate change to the fixture project — and commit what it
  produces. Between those, the suite reads and never writes.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    # Resolved at runtime rather than aliased: `TestAdapter` is compiled from
    # `test/support`, which is only on the path in `:test`, and a direct
    # reference would fail to compile this task in every other environment.
    # `adapter.fun()` on a variable is runtime dispatch just as `apply/3` is,
    # without the arity credo objects to.
    adapter = Module.concat([CodeMySpec, Support, TestAdapter])
    ensure_adapter_available!(adapter)

    Mix.shell().info("Cloning fixture repositories and recording analyzer output…")
    adapter.ensure_fixture_fresh()

    copy_recorded_output(adapter)

    Mix.shell().info("""

    Done. Committed fixtures are in #{adapter.fixture_output_dir()}.
    Review the diff before committing — a change here changes what the suite
    believes the analyzers produce.
    """)
  end

  # `ensure_fixture_fresh/0` writes beside the fixture repositories, which is
  # where it has always written and where the generating commands are pointed.
  # The committed copies are what the suite reads, so the last step is to bring
  # them across rather than to re-point every generator at a second location.
  defp copy_recorded_output(adapter) do
    dest = adapter.fixture_output_dir()
    File.mkdir_p!(dest)

    source_dir = Path.dirname(adapter.code_repo_fixture_path())

    for name <- recorded_files() do
      from = Path.join(source_dir, name)
      to = Path.join(dest, name)

      case File.cp(from, to) do
        :ok -> Mix.shell().info("  recorded #{name}")
        {:error, reason} -> Mix.shell().error("  #{name}: #{:file.format_error(reason)}")
      end
    end
  end

  defp recorded_files do
    ~w(
      compiler_ok_cache.json
      compiler_warnings_cache.json
      compiler_errors_cache.json
      test_results_cache.json
      test_results_failing_cache.json
      test_results_post_cache_failing_cache.json
      spex_results_passing_cache.jsonl
      spex_results_failing_cache.jsonl
    )
  end

  # Asks the real question rather than a proxy for it. The requirement is not
  # "the env is test", it is "TestAdapter is compiled" — it lives in
  # `test/support`, which is only on the path under `MIX_ENV=test`. Checking the
  # module also keeps a compile-time environment lookup out of `lib/`, which
  # `release_safety_test` forbids because it crashes in a compiled release.
  defp ensure_adapter_available!(adapter) do
    if not Code.ensure_loaded?(adapter) do
      Mix.raise("""
      #{inspect(adapter)} is not available.

      It is compiled from test/support, which is only on the path in the test
      environment. Run:

          MIX_ENV=test mix cms.test_fixtures
      """)
    end
  end
end
