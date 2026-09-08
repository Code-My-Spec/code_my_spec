defmodule CodeMySpec.Support.TestAdapter do
  @moduledoc """
  Test adapter for Git operations that uses a local fixture repository.

  Maintains a single fixture repository that is cloned once and kept fresh,
  then copies it for each test to avoid network calls and prevent test
  contention from concurrent modifications.

  ## Recorded analyzer output is committed, not generated

  The `*_cache_path/0` functions point into `test/fixtures/analyzer_output/`,
  which is in the repository. Roughly 60KB of JSON, and every test run reads it
  without producing it.

  It used to be generated at boot by `ensure_fixture_fresh/0`, called from
  `test_helper.exs` on every `mix test`. Most of that work was
  `File.exists?`-guarded and therefore cheap, but `ensure_repo_fresh/2` was not:
  it ran `git pull` in both fixture repositories every single time. Those live
  under `../code_my_spec_test_repos`, which every worktree reaches through a
  symlink to one shared directory — so two agents starting suites near each
  other were two pulls racing in one repository before a single test ran, and
  the analyzer tests then compiled and ran suites inside that same shared build
  tree. That is the contention behind the `** (EXIT …) killed` findings.

  Regenerate deliberately with `mix cms.test_fixtures` when the real tools
  change shape. Nothing in the test path regenerates anything.

  ## The live fixture project is still on disk

  `checkout/1` and `clone/4` hand out pooled copies of a real Phoenix project,
  which cannot be committed usefully — it is 9MB with a build tree. Only the
  analyzer tests need it, and the pool creates copies lazily, so a checkout
  without the fixture repository costs nothing until one of those tests asks
  for it. `mix cms.test_fixtures` is what puts it there.
  """

  @behaviour CodeMySpec.Git.Behaviour

  alias CodeMySpec.Compile
  alias CodeMySpec.Environments.Environment

  @code_repo_fixture_path "../code_my_spec_test_repos/test_phoenix_project"
  @content_repo_fixture_path "../code_my_spec_test_repos/test_content_repo"
  @code_fixture_url "https://github.com/Code-My-Spec/test_phoenix_project.git"
  @content_fixture_url "https://github.com/johns10/test_content_repo.git"

  # Committed. See the moduledoc.
  @fixture_output_dir "test/fixtures/analyzer_output"
  @test_results_cache "#{@fixture_output_dir}/test_results_cache.json"
  @test_results_failing_cache "#{@fixture_output_dir}/test_results_failing_cache.json"
  @test_results_post_cache_failing_cache "#{@fixture_output_dir}/test_results_post_cache_failing_cache.json"
  @compiler_ok_cache "#{@fixture_output_dir}/compiler_ok_cache.json"
  @compiler_warnings_cache "#{@fixture_output_dir}/compiler_warnings_cache.json"
  @compiler_errors_cache "#{@fixture_output_dir}/compiler_errors_cache.json"
  @spex_results_passing_cache "#{@fixture_output_dir}/spex_results_passing_cache.jsonl"
  @spex_results_failing_cache "#{@fixture_output_dir}/spex_results_failing_cache.jsonl"

  @doc "Where the fixture repositories live, for `mix cms.test_fixtures`."
  def code_repo_fixture_path, do: @code_repo_fixture_path
  def content_repo_fixture_path, do: @content_repo_fixture_path
  def code_fixture_url, do: @code_fixture_url
  def content_fixture_url, do: @content_fixture_url
  def fixture_output_dir, do: @fixture_output_dir

  @doc """
  Ensures the fixture repositories exist and are up to date.

  Clones the repositories if they don't exist, otherwise pulls latest changes.
  Generates and caches test results and compiler diagnostics if not already cached.

  **Not called from `test_helper.exs`.** This is `mix cms.test_fixtures`'s
  entry point and runs only when someone asks for it — see the moduledoc.
  """
  def ensure_fixture_fresh do
    ensure_repo_fresh(@code_repo_fixture_path, @code_fixture_url)
    ensure_repo_fresh(@content_repo_fixture_path, @content_fixture_url)

    if !File.exists?(@compiler_ok_cache) or !File.exists?(@compiler_warnings_cache) or
         !File.exists?(@compiler_errors_cache) or !File.exists?(@test_results_cache) or
         !File.exists?(@test_results_failing_cache) or
         !File.exists?(@test_results_post_cache_failing_cache) or
         !File.exists?(@spex_results_passing_cache) or
         !File.exists?(@spex_results_failing_cache) do
      IO.puts("[TestAdapter] Installing dependencies...")
      System.cmd("mix", ["deps.get"], cd: @code_repo_fixture_path, stderr_to_stdout: true)
    end

    generate_compiler_caches()
    generate_test_results_caches()
    generate_post_cache_failing_tests()
    generate_spex_results_caches()
    generate_dev_build()
  end

  @doc """
  Returns the path to the cached test results JSON file.
  """
  def test_results_cache_path, do: @test_results_cache

  @doc """
  Returns the path to the cached failing test results JSON file.
  """
  def test_results_failing_cache_path, do: @test_results_failing_cache

  @doc """
  Returns the path to the cached post cache failing test results JSON file.
  """
  def test_results_post_cache_failing_cache_path, do: @test_results_post_cache_failing_cache

  @doc """
  Returns the path to the cached clean compilation results JSON file.
  """
  def compiler_ok_cache_path, do: @compiler_ok_cache

  @doc """
  Returns the path to the cached compilation warnings results JSON file.
  """
  def compiler_warnings_cache_path, do: @compiler_warnings_cache

  @doc """
  Returns the path to the cached compilation errors results JSON file.
  """
  def compiler_errors_cache_path, do: @compiler_errors_cache

  @doc """
  Returns the path to the cached passing spex results JSONL file.
  """
  def spex_results_passing_cache_path, do: @spex_results_passing_cache

  @doc """
  Returns the path to the cached failing spex results JSONL file.
  """
  def spex_results_failing_cache_path, do: @spex_results_failing_cache

  @doc """
  Checkout a directory from the pool for fast test setup.

  Instead of rsync-ing a fresh copy each time, this reuses directories from a pool.
  The directory is reset via git before being returned, so it's clean for tests.
  All directories include deps, _build, and .git.

  Returns `{:ok, path}` where path is the directory to use.
  """
  def checkout(opts \\ []) do
    __MODULE__.Pool.checkout(opts)
  end

  @doc """
  Return a directory to the pool after test is complete.

  This resets the git state and makes the directory available for reuse.
  Call this in `on_exit` instead of `File.rm_rf!`.
  """
  def checkin(path) do
    __MODULE__.Pool.checkin(path)
  end

  @doc """
  Clones a repository by checking out from the pool.

  Uses a pool of pre-cloned directories for fast reuse. Additional arguments
  are ignored for backward compatibility - the pool manages paths and always
  includes deps, _build, and .git.

  Use `checkin/1` in `on_exit` to return the directory to the pool.
  """
  @impl true
  def clone(_scope, repo_url, _path \\ nil, _opts \\ []) do
    repo_type = url_to_repo_type(repo_url)
    __MODULE__.Pool.checkout(repo_type: repo_type)
  end

  defp url_to_repo_type(repo_url) do
    if String.contains?(repo_url, "test_content_repo"), do: :content_repo, else: :code_repo
  end

  @doc """
  Simulates a pull operation.

  Since tests use copies of the fixture, pull operations are no-ops.
  Returns :ok to satisfy the behaviour contract.
  """
  @impl true
  def pull(_scope, _path) do
    :ok
  end

  defp ensure_repo_fresh(fixture_path, fixture_url) do
    if File.exists?(fixture_path) do
      pull_repo(fixture_path)
    else
      clone_repo(fixture_path, fixture_url)
    end
  end

  defp clone_repo(fixture_path, fixture_url) do
    File.mkdir_p!(Path.dirname(fixture_path))
    IO.puts("[TestAdapter] Cloning #{fixture_url} (only happens once)...")

    case System.cmd(
           "git",
           ["clone", "--recurse-submodules", fixture_url, fixture_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        raise """
        Failed to clone fixture repository.
        URL: #{fixture_url}
        Exit code: #{code}
        Output: #{output}
        """
    end
  end

  # Every checkout on this machine pulls the *same* fixture clone, so two agents
  # running `mix test` at once land in one another's fetch. That surfaced as
  # `fatal: Cannot rebase onto multiple branches` and took the whole suite down
  # before a single test ran — a message with nothing to do with the code under
  # test, on a run that would have passed.
  #
  # Same shape as the shared test database, and the same fix is not available:
  # the clone is expensive and deliberately shared. So: retry, and if it still
  # will not pull, distinguish the two things the failure could mean. A fixture
  # that is *absent* is fatal — there is nothing to test against. A fixture that
  # is present at a good commit and merely could not be *refreshed* is a stale
  # fixture, which is a different and much smaller problem than no fixture.
  #
  # Loud either way. The one outcome worth ruling out is a silent pass on a
  # fixture nobody knows is old.
  @pull_attempts 3

  defp pull_repo(fixture_path, attempt \\ 1) do
    case System.cmd("git", ["pull", "--recurse-submodules"],
           cd: fixture_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Also update submodules after pull
        case System.cmd("git", ["submodule", "update", "--init", "--recursive"],
               cd: fixture_path,
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          {output, code} ->
            raise """
            Failed to update submodules.
            Path: #{fixture_path}
            Exit code: #{code}
            Output: #{output}
            """
        end

      {_output, _code} when attempt < @pull_attempts ->
        Process.sleep(attempt * 500)
        pull_repo(fixture_path, attempt + 1)

      {output, code} ->
        sha =
          usable_commit(fixture_path) ||
            raise """
            Failed to pull fixture repository, and it is not usable as it stands.
            Path: #{fixture_path}
            Exit code: #{code}
            Output: #{output}
            """

        IO.warn("""
        [TestAdapter] could not refresh #{fixture_path} after #{@pull_attempts} attempts \
        — running against the commit already on disk (#{sha}).

        Exit code: #{code}
        Output: #{output}

        Usually another checkout's `mix test` pulling this same clone at the same
        moment. The fixture is stale rather than missing, so the suite runs; if
        tests fail in ways the code does not explain, refresh it by hand first.
        """)

        :ok
    end
  end

  # A commit id if the repo is on one and no merge or rebase is half-finished,
  # nil otherwise. `git pull` failing mid-rebase leaves a tree that will fail
  # every test for reasons that have nothing to do with the code.
  defp usable_commit(fixture_path) do
    interrupted? =
      Enum.any?(
        ~w(rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD),
        &File.exists?(Path.join([fixture_path, ".git", &1]))
      )

    with false <- interrupted?,
         {sha, 0} <-
           System.cmd("git", ["rev-parse", "--short", "HEAD"],
             cd: fixture_path,
             stderr_to_stdout: true
           ) do
      String.trim(sha)
    else
      _ -> nil
    end
  end

  defp generate_test_results_caches do
    # Only generate if cache doesn't exist
    if not File.exists?(@test_results_cache) do
      # Run tests and write JSON to file (passing tests)
      IO.puts("[TestAdapter] Running passing tests...")
      test_results_file = "test_results.json"

      # env inherits all vars and overrides/adds those specified
      System.cmd("mix", ["test", "--formatter", "ClientUtils.TestFormatter"],
        cd: @code_repo_fixture_path,
        stderr_to_stdout: true,
        env: [{"EXUNIT_JSON_OUTPUT_FILE", test_results_file}]
      )

      # Copy test results to cache location
      IO.puts("[TestAdapter] Caching passing test results...")
      File.mkdir_p!(Path.dirname(@test_results_cache))
      File.cp!(Path.join(@code_repo_fixture_path, test_results_file), @test_results_cache)

      # Remove test results file
      test_results_path = Path.join(@code_repo_fixture_path, test_results_file)
      File.rm!(test_results_path)

      # Now generate failing test cache
      IO.puts("[TestAdapter] Setting up failing test...")
      failing_test_content = File.read!("test/fixtures/component_coding/post_repository_test._ex")

      test_path =
        Path.join([
          @code_repo_fixture_path,
          "test",
          "test_phoenix_project",
          "blog",
          "post_repository_test.exs"
        ])

      File.mkdir_p!(Path.dirname(test_path))
      File.write!(test_path, failing_test_content)

      # Run tests with failing test
      IO.puts("[TestAdapter] Running tests with failing test...")
      test_results_failing_file = "test_results_failing.json"

      System.cmd("mix", ["test", "--formatter", "ClientUtils.TestFormatter"],
        cd: @code_repo_fixture_path,
        stderr_to_stdout: true,
        env: [{"EXUNIT_JSON_OUTPUT_FILE", test_results_failing_file}]
      )

      # Copy failing test results to cache location
      IO.puts("[TestAdapter] Caching failing test results...")
      File.mkdir_p!(Path.dirname(@test_results_failing_cache))

      File.cp!(
        Path.join(@code_repo_fixture_path, test_results_failing_file),
        @test_results_failing_cache
      )

      # Restore the original test file from git
      IO.puts("[TestAdapter] Restoring original test file from git...")

      System.cmd("git", ["restore", "test/test_phoenix_project/blog/post_repository_test.exs"],
        cd: @code_repo_fixture_path,
        stderr_to_stdout: true
      )

      # Remove failing test results file
      test_results_failing_path = Path.join(@code_repo_fixture_path, test_results_failing_file)
      File.rm!(test_results_failing_path)

      IO.puts("[TestAdapter] Cache generation complete!\n")
    end
  end

  defp generate_post_cache_failing_tests do
    # Only generate if cache doesn't exist
    if not File.exists?(@test_results_post_cache_failing_cache) do
      IO.puts("[TestAdapter] Setting up post cache failing tests...")

      # Read the fixture test file
      failing_test_content = File.read!("test/fixtures/component_coding/post_cache_test._ex")

      # Determine the target test path in the fixture repo
      test_path =
        Path.join([
          @code_repo_fixture_path,
          "test",
          "test_phoenix_project",
          "blog",
          "post_cache_test.exs"
        ])

      # Ensure the directory exists and write the test file
      File.mkdir_p!(Path.dirname(test_path))
      File.write!(test_path, failing_test_content)

      # Run tests with the post cache test (all should fail)
      IO.puts("[TestAdapter] Running post cache tests (expecting failures)...")
      test_results_file = "test_results_post_cache_failing.json"

      System.cmd(
        "mix",
        [
          "test",
          "test/test_phoenix_project/blog/post_cache_test.exs",
          "--formatter",
          "ClientUtils.TestFormatter"
        ],
        cd: @code_repo_fixture_path,
        stderr_to_stdout: true,
        env: [{"EXUNIT_JSON_OUTPUT_FILE", test_results_file}]
      )

      # Copy test results to cache location
      IO.puts("[TestAdapter] Caching post cache failing test results...")
      File.mkdir_p!(Path.dirname(@test_results_post_cache_failing_cache))

      File.cp!(
        Path.join(@code_repo_fixture_path, test_results_file),
        @test_results_post_cache_failing_cache
      )

      # Clean up the test file (remove it since it shouldn't be in the repo)
      IO.puts("[TestAdapter] Cleaning up post cache test file...")
      File.rm!(test_path)

      # Remove test results file
      test_results_path = Path.join(@code_repo_fixture_path, test_results_file)
      File.rm!(test_results_path)

      IO.puts("[TestAdapter] Post cache failing test cache generation complete!")
    end
  end

  defp generate_compiler_caches do
    # Expand paths to absolute paths
    code_repo_fixture_abs = Path.expand(@code_repo_fixture_path)

    warnings_file_path = Path.join([code_repo_fixture_abs, "lib", "warnings.ex"])
    errors_file_path = Path.join([code_repo_fixture_abs, "lib", "errors.ex"])

    # Expand cache paths to absolute paths
    compiler_ok_cache_abs = Path.expand(@compiler_ok_cache)
    compiler_warnings_cache_abs = Path.expand(@compiler_warnings_cache)
    compiler_errors_cache_abs = Path.expand(@compiler_errors_cache)

    if not File.exists?(@compiler_ok_cache) do
      # 1. Generate clean compilation cache
      IO.puts("[TestAdapter] Generating clean compilation cache...")

      # Clean build to ensure fresh compilation
      File.rm_rf!(Path.join(code_repo_fixture_abs, "_build"))

      result =
        Compile.execute(environment: Environment.new(:local, code_repo_fixture_abs))

      save_compile_result(result, compiler_ok_cache_abs)

      if !File.exists?(compiler_ok_cache_abs), do: raise("Compiler OK cache failed to be created")
    end

    if not File.exists?(@compiler_warnings_cache) do
      # 2. Generate compilation warnings cache
      IO.puts("[TestAdapter] Generating compilation warnings cache...")

      # Copy warnings fixture to lib/warnings.ex
      warnings_fixture = "test/fixtures/compiler/post_repository_warnings._ex"
      File.cp!(warnings_fixture, warnings_file_path)

      # Clean and recompile to get warnings
      File.rm_rf!(Path.join(code_repo_fixture_abs, "_build"))

      result =
        Compile.execute(environment: Environment.new(:local, code_repo_fixture_abs))

      save_compile_result(result, compiler_warnings_cache_abs)

      if !File.exists?(compiler_warnings_cache_abs),
        do: raise("Compiler warnings cache failed to be created")

      # Delete warnings file
      File.rm!(warnings_file_path)
    end

    if not File.exists?(@compiler_errors_cache) do
      # 3. Generate compilation errors cache
      IO.puts("[TestAdapter] Generating compilation errors cache...")

      # Copy errors fixture to lib/errors.ex
      errors_fixture = "test/fixtures/compiler/post_repository_errors._ex"
      File.cp!(errors_fixture, errors_file_path)

      # Clean and recompile to get errors
      File.rm_rf!(Path.join(code_repo_fixture_abs, "_build"))

      result =
        Compile.execute(environment: Environment.new(:local, code_repo_fixture_abs))

      save_compile_result(result, compiler_errors_cache_abs)

      if !File.exists?(compiler_errors_cache_abs),
        do: raise("Compiler errors cache failed to be created")

      # Delete errors file
      File.rm!(errors_file_path)

      # Clean build directory one final time
      File.rm_rf!(Path.join(code_repo_fixture_abs, "_build"))
    end

    IO.puts("[TestAdapter] Compiler cache generation complete!")
  end

  defp generate_dev_build do
    code_repo_fixture_abs = Path.expand(@code_repo_fixture_path)
    dev_build_path = Path.join(code_repo_fixture_abs, "_build/dev")

    if not File.exists?(dev_build_path) do
      IO.puts("[TestAdapter] Compiling dev environment for static analysis tools...")

      System.cmd("mix", ["compile"],
        cd: code_repo_fixture_abs,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

      IO.puts("[TestAdapter] Dev build complete!")
    end
  end

  defp generate_spex_results_caches do
    # Only generate if caches don't exist
    if not File.exists?(@spex_results_passing_cache) do
      IO.puts("[TestAdapter] Running passing spex tests...")

      # Run mix spex with passing tests
      {_output, _exit_code} =
        System.cmd(
          "mix",
          ["spex", "test/spex/sample_spex.exs", "--jsonl=spex_passing.jsonl"],
          cd: @code_repo_fixture_path,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      # Copy JSONL to cache location
      IO.puts("[TestAdapter] Caching passing spex results...")
      File.mkdir_p!(Path.dirname(@spex_results_passing_cache))

      spex_output = Path.join(@code_repo_fixture_path, "spex_passing.jsonl")

      if File.exists?(spex_output) do
        File.cp!(spex_output, @spex_results_passing_cache)
        File.rm!(spex_output)
      else
        # Create empty file if no failures (all passed)
        File.write!(@spex_results_passing_cache, "")
      end
    end

    if not File.exists?(@spex_results_failing_cache) do
      IO.puts("[TestAdapter] Setting up failing spex test...")

      # Create a failing spex test
      failing_spex_content = """
      defmodule TestPhoenixProject.FailingSpex do
        use SexySpex

        spex "Failing example" do
          scenario "intentional failure" do
            given_ "a precondition" do
              :ok
            end

            when_ "an action occurs" do
              :ok
            end

            then_ "it should fail" do
              assert 1 == 2, "Intentional test failure"
            end
          end
        end
      end
      """

      failing_spex_path =
        Path.join([@code_repo_fixture_path, "test", "spex", "failing_spex.exs"])

      File.mkdir_p!(Path.dirname(failing_spex_path))
      File.write!(failing_spex_path, failing_spex_content)

      # Run mix spex with failing test
      IO.puts("[TestAdapter] Running failing spex tests...")

      {_output, _exit_code} =
        System.cmd(
          "mix",
          ["spex", "test/spex/failing_spex.exs", "--jsonl=spex_failing.jsonl"],
          cd: @code_repo_fixture_path,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      # Copy JSONL to cache location
      IO.puts("[TestAdapter] Caching failing spex results...")
      File.mkdir_p!(Path.dirname(@spex_results_failing_cache))

      spex_output = Path.join(@code_repo_fixture_path, "spex_failing.jsonl")

      if File.exists?(spex_output) do
        File.cp!(spex_output, @spex_results_failing_cache)
        File.rm!(spex_output)
      else
        # Shouldn't happen, but create empty file as fallback
        File.write!(@spex_results_failing_cache, "")
      end

      # Clean up failing test file
      File.rm!(failing_spex_path)

      IO.puts("[TestAdapter] Spex cache generation complete!")
    end
  end

  defp save_compile_result(result, cache_path) do
    File.mkdir_p!(Path.dirname(cache_path))
    File.cp!(result.output_file, cache_path)
  end
end
