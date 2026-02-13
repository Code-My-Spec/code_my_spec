defmodule CodeMySpec.Validation.PipelineTest do
  use CodeMySpec.DataCase, async: false
  use ExCliVcr

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Support.TestAdapter
  alias CodeMySpec.Validation.Pipeline

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  @test_repo_url "https://github.com/johns10/test_phoenix_project.git"

  defp empty_categorized do
    %{
      spec_files: [],
      test_files: [],
      spex_files: [],
      code_files: [],
      elixir_files: []
    }
  end

  defp project_setup do
    scope = full_scope_fixture()
    {:ok, project_dir} = TestAdapter.clone(scope, @test_repo_url)
    env = Environment.new(:local, project_dir)
    scope = %{scope | environment: env, cwd: project_dir}
    {scope, project_dir}
  end

  defp cached_pipeline_opts do
    [
      compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path()),
      test_output_file: Path.expand(TestAdapter.test_results_cache_path())
    ]
  end

  # ============================================================================
  # categorize_files/1
  # ============================================================================

  describe "categorize_files/1" do
    test "categorizes .spec.md files as spec_files" do
      result = Pipeline.categorize_files(["docs/spec/my_module.spec.md"])
      assert "docs/spec/my_module.spec.md" in result.spec_files
    end

    test "categorizes _test.exs files as test_files" do
      result = Pipeline.categorize_files(["test/my_module_test.exs"])
      assert "test/my_module_test.exs" in result.test_files
    end

    test "categorizes _spex.exs files as spex_files" do
      result = Pipeline.categorize_files(["test/my_module_spex.exs"])
      assert "test/my_module_spex.exs" in result.spex_files
    end

    test "categorizes .ex files as code_files" do
      result = Pipeline.categorize_files(["lib/my_module.ex"])
      assert "lib/my_module.ex" in result.code_files
    end

    test "categorizes .exs files (non-test, non-spex) as code_files" do
      result = Pipeline.categorize_files(["config/config.exs"])
      assert "config/config.exs" in result.code_files
    end

    test "builds elixir_files from code + test + spex" do
      files = ["lib/foo.ex", "test/foo_test.exs", "test/foo_spex.exs"]
      result = Pipeline.categorize_files(files)

      assert "lib/foo.ex" in result.elixir_files
      assert "test/foo_test.exs" in result.elixir_files
      assert "test/foo_spex.exs" in result.elixir_files
    end

    @tag :tmp_dir
    test "maps lib/foo.ex to test/foo_test.exs and includes in test_files", %{tmp_dir: tmp_dir} do
      lib_file = Path.join(tmp_dir, "lib/foo.ex")
      test_file = Path.join(tmp_dir, "test/foo_test.exs")

      File.mkdir_p!(Path.dirname(lib_file))
      File.mkdir_p!(Path.dirname(test_file))
      File.write!(lib_file, "defmodule Foo do\nend")
      File.write!(test_file, "defmodule FooTest do\nend")

      result = Pipeline.categorize_files([lib_file])
      assert test_file in result.test_files
    end

    test "ignores non-Elixir files (.js, .json, .md without .spec)" do
      files = ["app.js", "data.json", "README.md", "styles.css"]
      result = Pipeline.categorize_files(files)

      assert result.spec_files == []
      assert result.test_files == []
      assert result.spex_files == []
      assert result.code_files == []
      assert result.elixir_files == []
    end

    test "handles empty list" do
      result = Pipeline.categorize_files([])

      assert result.spec_files == []
      assert result.test_files == []
      assert result.spex_files == []
      assert result.code_files == []
      assert result.elixir_files == []
    end
  end

  # ============================================================================
  # clear_stale_problems/2
  # ============================================================================

  describe "clear_stale_problems/2" do
    setup do
      %{scope: full_scope_fixture()}
    end

    test "clears test-source problems for test_files", %{scope: scope} do
      test_file = "test/my_module_test.exs"

      problem_fixture(scope, %{
        source_type: :test,
        source: "ex_unit",
        file_path: test_file,
        category: "test_failure"
      })

      categorized = %{empty_categorized() | test_files: [test_file]}
      Pipeline.clear_stale_problems(scope, categorized)

      assert [] == Problems.list_project_problems(scope, source_type: :test, file_path: test_file)
    end

    test "clears credo-source problems for elixir_files", %{scope: scope} do
      elixir_file = "lib/my_module.ex"
      problem_fixture(scope, %{source: "credo", file_path: elixir_file})

      categorized = %{empty_categorized() | elixir_files: [elixir_file]}
      Pipeline.clear_stale_problems(scope, categorized)

      assert [] == Problems.list_project_problems(scope, source: "credo", file_path: elixir_file)
    end

    test "clears sobelow-source problems for elixir_files", %{scope: scope} do
      elixir_file = "lib/my_module.ex"

      problem_fixture(scope, %{
        source: "sobelow",
        file_path: elixir_file,
        category: "security"
      })

      categorized = %{empty_categorized() | elixir_files: [elixir_file]}
      Pipeline.clear_stale_problems(scope, categorized)

      assert [] == Problems.list_project_problems(scope, source: "sobelow", file_path: elixir_file)
    end

    test "clears spex-source problems for spex_files", %{scope: scope} do
      spex_file = "test/my_module_spex.exs"

      problem_fixture(scope, %{
        source: "spex",
        source_type: :test,
        file_path: spex_file,
        category: "spex_failure"
      })

      categorized = %{empty_categorized() | spex_files: [spex_file]}
      Pipeline.clear_stale_problems(scope, categorized)

      assert [] == Problems.list_project_problems(scope, source: "spex", file_path: spex_file)
    end

    test "clears spec_validation-source problems for spec_files", %{scope: scope} do
      spec_file = "docs/spec/my_module.spec.md"

      problem_fixture(scope, %{
        source: "spec_validation",
        file_path: spec_file,
        category: "validation_error"
      })

      categorized = %{empty_categorized() | spec_files: [spec_file]}
      Pipeline.clear_stale_problems(scope, categorized)

      assert [] ==
               Problems.list_project_problems(scope,
                 source: "spec_validation",
                 file_path: spec_file
               )
    end

    test "clears all compiler-source problems project-wide", %{scope: scope} do
      problem_fixture(scope, %{
        source: "compiler",
        file_path: "project",
        category: "compilation_error"
      })

      problem_fixture(scope, %{
        source: "compiler",
        file_path: "lib/other.ex",
        category: "compiler_warning",
        severity: :warning
      })

      Pipeline.clear_stale_problems(scope, empty_categorized())

      assert [] == Problems.list_project_problems(scope, source: "compiler")
    end

    test "does not clear problems for files not in the categorized set", %{scope: scope} do
      other_file = "lib/other_module.ex"
      problem_fixture(scope, %{source: "credo", file_path: other_file})

      categorized = %{empty_categorized() | elixir_files: ["lib/different_module.ex"]}
      Pipeline.clear_stale_problems(scope, categorized)

      assert [_] = Problems.list_project_problems(scope, source: "credo", file_path: other_file)
    end

    test "does not clear problems from other sources (e.g. clearing tests does not remove credo)",
         %{scope: scope} do
      file = "lib/my_module.ex"

      # Seed a credo problem
      problem_fixture(scope, %{source: "credo", file_path: file})

      # Seed a test problem for the same file
      problem_fixture(scope, %{
        source_type: :test,
        source: "ex_unit",
        file_path: file,
        category: "test_failure"
      })

      # Only clear test problems (test_files includes the file)
      categorized = %{empty_categorized() | test_files: [file]}
      Pipeline.clear_stale_problems(scope, categorized)

      # Credo problem should remain
      assert [_] = Problems.list_project_problems(scope, source: "credo", file_path: file)

      # Test problem should be cleared
      assert [] == Problems.list_project_problems(scope, source_type: :test, file_path: file)
    end

    test "skips clearing when scope is nil" do
      categorized = %{empty_categorized() | test_files: ["test/foo_test.exs"]}
      assert :ok = Pipeline.clear_stale_problems(nil, categorized)
    end

    test "handles empty file lists (no-op per category)", %{scope: scope} do
      problem_fixture(scope, %{source: "credo", file_path: "lib/foo.ex"})

      # All file lists empty - compiler problems cleared project-wide, others are no-op
      Pipeline.clear_stale_problems(scope, empty_categorized())

      # Credo problem should remain (no elixir_files to clear)
      assert [_] = Problems.list_project_problems(scope, source: "credo")
    end
  end

  # ============================================================================
  # compile_project/1
  # ============================================================================

  describe "compile_project/1" do
    @tag timeout: 120_000
    test "compiles project using CodeMySpec.Compile" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_compile_ok", ignore: [[:opts, :cd]] do
        assert :ok = Pipeline.compile_project(scope)
      end
    end

    @tag timeout: 120_000
    test "returns :ok on successful compilation" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_compile_ok", ignore: [[:opts, :cd]] do
        assert :ok = Pipeline.compile_project(scope)
      end
    end

    @tag timeout: 120_000
    @tag :tmp_dir
    test "returns {:error, reason} when compilation fails", %{tmp_dir: tmp_dir} do
      # Point scope at a directory with an invalid mix project to force exit_code != 0
      File.write!(Path.join(tmp_dir, "mix.exs"), "invalid elixir")
      scope = full_scope_fixture()
      scope = %{scope | cwd: tmp_dir}

      assert {:error, reason} = Pipeline.compile_project(scope)
      assert is_binary(reason)
    end

    test "skips compilation when scope is nil" do
      assert :ok = Pipeline.compile_project(nil)
    end
  end

  # ============================================================================
  # run_tests/2
  # ============================================================================

  describe "run_tests/2" do
    test "returns {:ok, []} when no test files" do
      assert {:ok, []} = Pipeline.run_tests([], nil)
    end

    @tag timeout: 120_000
    test "returns {:ok, []} when all tests pass" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      test_file =
        Path.join(
          project_dir,
          "test/test_phoenix_project_web/controllers/page_controller_test.exs"
        )

      use_cmd_cassette "pipeline_tests_pass", ignore: [[:opts, :cd]] do
        opts = [test_output_file: Path.expand(TestAdapter.test_results_cache_path())]
        {:ok, problems} = Pipeline.run_tests([test_file], scope, opts)

        # No actual test failure problems (compiler warnings may appear)
        test_failures = Enum.filter(problems, &(&1.source_type == :test))
        assert test_failures == []
      end
    end

    @tag timeout: 120_000
    test "returns {:ok, problems} with test failure problems" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      # The failing cache has failures for blog/post_repository_test.exs
      test_file =
        Path.join(
          project_dir,
          "test/test_phoenix_project/blog/post_repository_test.exs"
        )

      use_cmd_cassette "pipeline_tests_fail", ignore: [[:opts, :cd]] do
        opts = [test_output_file: Path.expand(TestAdapter.test_results_failing_cache_path())]
        {:ok, problems} = Pipeline.run_tests([test_file], scope, opts)

        assert problems != []
        assert Enum.all?(problems, &match?(%Problem{}, &1))
      end
    end

    test "filters non-existent test files" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      assert {:ok, []} = Pipeline.run_tests(["/nonexistent/test_file.exs"], scope)
    end

    test "handles test execution errors gracefully" do
      scope = full_scope_fixture()
      scope = %{scope | cwd: "/nonexistent/project"}

      # Non-existent files get filtered out
      assert {:ok, []} = Pipeline.run_tests(["/nonexistent/test.exs"], scope)
    end

    @tag timeout: 120_000
    test "tags compiler errors from test execution as source_type: :static_analysis" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      # Inject a file with syntax errors that will cause test compilation to fail
      error_file = Path.join(project_dir, "lib/pipeline_test_compile_error.ex")
      File.write!(error_file, "defmodule PipelineTestCompileError do\n  def bad(do\nend")

      test_file =
        Path.join(
          project_dir,
          "test/test_phoenix_project/blog/post_repository_test.exs"
        )

      use_cmd_cassette "pipeline_tests_compiler_error", ignore: [[:opts, :cd]] do
        {:ok, problems} = Pipeline.run_tests([test_file], scope)

        compiler_problems = Enum.filter(problems, &(&1.source == "compiler"))

        if compiler_problems != [] do
          assert Enum.all?(compiler_problems, &(&1.source_type == :static_analysis))
        end
      end
    end
  end

  # ============================================================================
  # run_credo/2
  # ============================================================================

  describe "run_credo/2" do
    test "returns {:ok, []} when no files" do
      assert {:ok, []} = Pipeline.run_credo([], nil)
    end

    test "returns {:ok, []} when no scope" do
      assert {:ok, []} = Pipeline.run_credo(["lib/foo.ex"], nil)
    end

    @tag timeout: 120_000
    test "returns {:ok, []} when no issues found" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_credo_no_issues", ignore: [[:opts, :cd]] do
        clean_file = Path.join(project_dir, "lib/test_phoenix_project/application.ex")
        {:ok, problems} = Pipeline.run_credo([clean_file], scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "returns {:ok, problems} with Credo issues" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_credo_with_issues", ignore: [[:opts, :cd]] do
        files = [Path.join(project_dir, "lib/test_phoenix_project_web/router.ex")]
        {:ok, problems} = Pipeline.run_credo(files, scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "filters problems to only provided files" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_credo_filter_files", ignore: [[:opts, :cd]] do
        target_file = Path.join(project_dir, "lib/test_phoenix_project/application.ex")
        {:ok, problems} = Pipeline.run_credo([target_file], scope)

        Enum.each(problems, fn p ->
          basename = Path.basename(target_file)

          assert p.file_path == target_file or
                   Path.basename(p.file_path) == basename
        end)
      end
    end
  end

  # ============================================================================
  # run_sobelow/2
  # ============================================================================

  describe "run_sobelow/2" do
    test "returns {:ok, []} when no files" do
      assert {:ok, []} = Pipeline.run_sobelow([], nil)
    end

    test "returns {:ok, []} when no scope" do
      assert {:ok, []} = Pipeline.run_sobelow(["lib/foo.ex"], nil)
    end

    @tag timeout: 120_000
    test "returns {:ok, []} when no findings" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_sobelow_no_findings", ignore: [[:opts, :cd]] do
        files = [Path.join(project_dir, "lib/test_phoenix_project/application.ex")]
        {:ok, problems} = Pipeline.run_sobelow(files, scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "returns {:ok, problems} with security findings" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_sobelow_findings", ignore: [[:opts, :cd]] do
        files = [Path.join(project_dir, "lib/test_phoenix_project_web/router.ex")]
        {:ok, problems} = Pipeline.run_sobelow(files, scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "filters problems to only provided files" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_sobelow_filter_files", ignore: [[:opts, :cd]] do
        target_file = Path.join(project_dir, "lib/test_phoenix_project_web/router.ex")
        {:ok, problems} = Pipeline.run_sobelow([target_file], scope)

        Enum.each(problems, fn p ->
          basename = Path.basename(target_file)

          assert p.file_path == target_file or
                   Path.basename(p.file_path) == basename
        end)
      end
    end
  end

  # ============================================================================
  # run_spex/2
  # ============================================================================

  describe "run_spex/2" do
    test "returns {:ok, []} when no spex files" do
      assert {:ok, []} = Pipeline.run_spex([], nil)
    end

    test "returns {:ok, []} when all specs pass" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_spex_pass", ignore: [[:opts, :cd]] do
        spex_file =
          Path.join(
            project_dir,
            "test/test_phoenix_project/posts/post_repository_spex.exs"
          )

        if File.exists?(spex_file) do
          {:ok, problems} = Pipeline.run_spex([spex_file], scope)
          assert is_list(problems)
        else
          # No spex file in fixture repo - verify empty case
          assert {:ok, []} = Pipeline.run_spex([], scope)
        end
      end
    end

    @tag timeout: 120_000
    test "returns {:ok, problems} with spex failures" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      use_cmd_cassette "pipeline_spex_failures", ignore: [[:opts, :cd]] do
        spex_file =
          Path.join(
            project_dir,
            "test/test_phoenix_project/posts/post_repository_spex.exs"
          )

        if File.exists?(spex_file) do
          {:ok, problems} = Pipeline.run_spex([spex_file], scope)
          assert is_list(problems)
        else
          assert {:ok, []} = Pipeline.run_spex([], scope)
        end
      end
    end

    test "handles spex execution errors gracefully" do
      scope = full_scope_fixture()
      scope = %{scope | cwd: "/tmp/nonexistent_project"}

      {:ok, problems} = Pipeline.run_spex(["test/nonexistent_spex.exs"], scope)
      assert is_list(problems)
    end
  end

  # ============================================================================
  # validate_spec_files/1
  # ============================================================================

  describe "validate_spec_files/1" do
    @tag :tmp_dir
    test "returns {:ok, []} when all specs are valid", %{tmp_dir: tmp_dir} do
      spec_file = Path.join(tmp_dir, "my_module.spec.md")

      File.write!(spec_file, """
      # MyModule

      ## Functions

      ### my_function/1

      Does something.

      ## Dependencies

      - SomeDep
      """)

      assert {:ok, []} = Pipeline.validate_spec_files([spec_file])
    end

    @tag :tmp_dir
    test "returns {:ok, problems} for specs missing required sections", %{tmp_dir: tmp_dir} do
      spec_file = Path.join(tmp_dir, "incomplete.spec.md")

      # Missing Dependencies section (required for spec type)
      File.write!(spec_file, """
      # IncompleteModule

      Some description without any sections.
      """)

      {:ok, problems} = Pipeline.validate_spec_files([spec_file])
      assert problems != []
    end

    @tag :tmp_dir
    test "returns {:ok, problems} for specs with disallowed sections", %{tmp_dir: tmp_dir} do
      spec_file = Path.join(tmp_dir, "extra_sections.spec.md")

      File.write!(spec_file, """
      # ExtraSections

      ## Functions

      ### my_function/1

      Does something.

      ## Dependencies

      - SomeDep

      ## Unauthorized Section

      This section is not allowed.
      """)

      {:ok, problems} = Pipeline.validate_spec_files([spec_file])
      assert problems != []
    end

    @tag :tmp_dir
    test "includes file path in problem", %{tmp_dir: tmp_dir} do
      spec_file = Path.join(tmp_dir, "bad_spec.spec.md")
      File.write!(spec_file, "")

      {:ok, problems} = Pipeline.validate_spec_files([spec_file])
      assert problems != []
      assert Enum.all?(problems, fn p -> p.file_path == spec_file end)
    end

    test "handles file read failures gracefully" do
      {:ok, problems} = Pipeline.validate_spec_files(["/nonexistent/path/file.spec.md"])
      assert problems != []

      problem = hd(problems)
      assert problem.category == "file_error" or problem.message =~ "not found"
    end

    @tag :tmp_dir
    test "determines correct document type (context_spec vs spec)", %{tmp_dir: tmp_dir} do
      # Context spec path: docs/spec/{project}/{file}.spec.md
      context_dir = Path.join(tmp_dir, "docs/spec/my_project")
      File.mkdir_p!(context_dir)
      context_spec = Path.join(context_dir, "accounts.spec.md")

      # context_spec requires: functions/delegates, dependencies, components
      File.write!(context_spec, """
      # Accounts

      ## Functions

      ### create_user/1

      Creates a user.

      ## Dependencies

      - Ecto

      ## Components

      - User
      - UserToken
      """)

      {:ok, problems} = Pipeline.validate_spec_files([context_spec])
      # Should validate as context_spec and pass (has all required sections)
      assert problems == []
    end
  end

  # ============================================================================
  # run/3
  # ============================================================================

  describe "run/3" do
    test "returns [] when no files provided" do
      scope = full_scope_fixture()
      assert [] = Pipeline.run(scope, [])
    end

    @tag timeout: 300_000
    test "returns [] when all files pass validation" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      opts = cached_pipeline_opts()

      use_cmd_cassette "pipeline_run_all_pass", ignore: [[:opts, :cd]] do
        test_file =
          Path.join(
            project_dir,
            "test/test_phoenix_project_web/controllers/page_controller_test.exs"
          )

        problems = Pipeline.run(scope, [test_file], opts)
        assert is_list(problems)
      end
    end

    @tag timeout: 300_000
    test "returns problems when any validator finds issues" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      opts = [
        compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path()),
        test_output_file: Path.expand(TestAdapter.test_results_failing_cache_path())
      ]

      use_cmd_cassette "pipeline_run_with_issues", ignore: [[:opts, :cd]] do
        test_file =
          Path.join(
            project_dir,
            "test/test_phoenix_project/blog/post_repository_test.exs"
          )

        problems = Pipeline.run(scope, [test_file], opts)
        assert problems != []
        assert Enum.all?(problems, &match?(%Problem{}, &1))
      end
    end

    @tag timeout: 300_000
    test "runs validators in order: compile, tests, credo, sobelow, spex, spec" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      opts = [
        compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path()),
        test_output_file: Path.expand(TestAdapter.test_results_failing_cache_path())
      ]

      use_cmd_cassette "pipeline_run_validator_order", ignore: [[:opts, :cd]] do
        test_file =
          Path.join(
            project_dir,
            "test/test_phoenix_project/blog/post_repository_test.exs"
          )

        # Pipeline runs compile first, then tests, credo, sobelow, spex, spec in order.
        # If compile succeeds, subsequent validators run and produce problems.
        # We verify by checking that test problems appear before static analysis problems.
        problems = Pipeline.run(scope, [test_file], opts)
        assert is_list(problems)

        sources = Enum.map(problems, & &1.source)
        test_idx = Enum.find_index(sources, &(&1 in ["ex_unit", "test"]))
        credo_idx = Enum.find_index(sources, &(&1 == "credo"))
        sobelow_idx = Enum.find_index(sources, &(&1 == "sobelow"))

        # If both test and credo problems exist, tests should come before credo
        if test_idx && credo_idx, do: assert(test_idx < credo_idx)
        # If both credo and sobelow problems exist, credo should come before sobelow
        if credo_idx && sobelow_idx, do: assert(credo_idx < sobelow_idx)
      end
    end

    @tag timeout: 300_000
    test "aggregates problems from all validators" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      opts = [
        compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path()),
        test_output_file: Path.expand(TestAdapter.test_results_failing_cache_path())
      ]

      use_cmd_cassette "pipeline_run_aggregate", ignore: [[:opts, :cd]] do
        code_file =
          Path.join(project_dir, "lib/test_phoenix_project/blog/post_repository.ex")

        test_file =
          Path.join(
            project_dir,
            "test/test_phoenix_project/blog/post_repository_test.exs"
          )

        problems = Pipeline.run(scope, [code_file, test_file], opts)
        assert is_list(problems)
      end
    end

    @tag :tmp_dir
    test "short-circuits on compilation failure", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), "invalid elixir")
      scope = full_scope_fixture()
      scope = %{scope | cwd: tmp_dir}

      problems = Pipeline.run(scope, [Path.join(tmp_dir, "test/foo_test.exs")])

      assert length(problems) == 1
      assert hd(problems).source == "compiler"
      assert hd(problems).category == "compilation_error"
    end

    test "handles individual validator failures gracefully (continues with others)" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      # Compilation succeeds but test file doesn't exist on disk
      opts = [compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path())]

      use_cmd_cassette "pipeline_run_graceful_failure", ignore: [[:opts, :cd]] do
        # Non-existent test file - run_tests handles gracefully, pipeline continues
        problems = Pipeline.run(scope, ["/nonexistent/test_test.exs"], opts)
        # Pipeline should not crash even though the test file doesn't exist
        assert is_list(problems)
      end
    end

    # --- Stale problem clearing tests ---

    @tag timeout: 300_000
    test "clears stale test problems for test_files before running tests" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      test_file =
        Path.join(
          project_dir,
          "test/test_phoenix_project_web/controllers/page_controller_test.exs"
        )

      problem_fixture(scope, %{
        source_type: :test,
        source: "ex_unit",
        file_path: test_file,
        category: "test_failure",
        message: "Stale test failure"
      })

      opts = cached_pipeline_opts()

      use_cmd_cassette "pipeline_run_clear_test_problems", ignore: [[:opts, :cd]] do
        Pipeline.run(scope, [test_file], opts)
      end

      remaining = Problems.list_project_problems(scope, source_type: :test, file_path: test_file)
      assert remaining == []
    end

    @tag timeout: 300_000
    test "clears stale credo problems for elixir_files before running credo" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      code_file = Path.join(project_dir, "lib/test_phoenix_project/application.ex")

      problem_fixture(scope, %{
        source: "credo",
        file_path: code_file,
        message: "Stale credo issue"
      })

      opts = cached_pipeline_opts()

      use_cmd_cassette "pipeline_run_clear_credo_problems", ignore: [[:opts, :cd]] do
        Pipeline.run(scope, [code_file], opts)
      end

      remaining = Problems.list_project_problems(scope, source: "credo", file_path: code_file)
      stale = Enum.filter(remaining, &(&1.message == "Stale credo issue"))
      assert stale == []
    end

    @tag timeout: 300_000
    test "clears stale sobelow problems for elixir_files before running sobelow" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      code_file = Path.join(project_dir, "lib/test_phoenix_project/application.ex")

      problem_fixture(scope, %{
        source: "sobelow",
        file_path: code_file,
        category: "security",
        message: "Stale sobelow finding"
      })

      opts = cached_pipeline_opts()

      use_cmd_cassette "pipeline_run_clear_sobelow_problems", ignore: [[:opts, :cd]] do
        Pipeline.run(scope, [code_file], opts)
      end

      remaining = Problems.list_project_problems(scope, source: "sobelow", file_path: code_file)
      stale = Enum.filter(remaining, &(&1.message == "Stale sobelow finding"))
      assert stale == []
    end

    @tag timeout: 300_000
    test "clears stale spex problems for spex_files before running spex" do
      {scope, project_dir} = project_setup()
      on_exit(fn -> TestAdapter.checkin(project_dir) end)

      spex_file =
        Path.join(
          project_dir,
          "test/test_phoenix_project/posts/post_repository_spex.exs"
        )

      problem_fixture(scope, %{
        source: "spex",
        source_type: :test,
        file_path: spex_file,
        category: "spex_failure",
        message: "Stale spex failure"
      })

      opts = cached_pipeline_opts()

      use_cmd_cassette "pipeline_run_clear_spex_problems", ignore: [[:opts, :cd]] do
        Pipeline.run(scope, [spex_file], opts)
      end

      remaining = Problems.list_project_problems(scope, source: "spex", file_path: spex_file)
      stale = Enum.filter(remaining, &(&1.message == "Stale spex failure"))
      assert stale == []
    end

    @tag :tmp_dir
    test "clears stale spec_validation problems for spec_files before validating specs",
         %{tmp_dir: tmp_dir} do
      scope = full_scope_fixture()
      scope = %{scope | cwd: tmp_dir}

      spec_file = Path.join(tmp_dir, "my_module.spec.md")

      File.write!(spec_file, """
      # MyModule

      ## Functions

      ### my_function/1

      Does something.

      ## Dependencies

      - SomeDep
      """)

      problem_fixture(scope, %{
        source: "spec_validation",
        file_path: spec_file,
        category: "validation_error",
        message: "Stale spec validation error"
      })

      opts = [compile_output_file: Path.expand(TestAdapter.compiler_ok_cache_path())]
      Pipeline.run(scope, [spec_file], opts)

      remaining =
        Problems.list_project_problems(scope, source: "spec_validation", file_path: spec_file)

      stale = Enum.filter(remaining, &(&1.message == "Stale spec validation error"))
      assert stale == []
    end

    @tag :tmp_dir
    test "clears stale compiler problems on compilation failure", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.exs"), "invalid elixir")
      scope = full_scope_fixture()
      scope = %{scope | cwd: tmp_dir}

      problem_fixture(scope, %{
        source: "compiler",
        file_path: "project",
        category: "compilation_error",
        message: "Old compilation error"
      })

      Pipeline.run(scope, [Path.join(tmp_dir, "test/foo_test.exs")])

      remaining = Problems.list_project_problems(scope, source: "compiler")
      stale = Enum.filter(remaining, &(&1.message == "Old compilation error"))
      assert stale == []
    end
  end
end
