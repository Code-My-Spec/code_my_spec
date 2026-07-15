defmodule CodeMySpec.BddSpecs.SpexTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.BddSpecs.Spex.Error
  alias CodeMySpec.BddSpecs.Spex.Failure
  alias CodeMySpec.BddSpecs.Spex.Step
  alias CodeMySpec.Support.TestAdapter

  @moduletag :tmp_dir

  # ============================================================================
  # parse_jsonl/1 - Unit tests with fixture files
  # ============================================================================

  describe "parse_jsonl/1" do
    test "parses multiple failure lines", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "failures.jsonl")

      content = """
      #{Jason.encode!(failure_json("User login", "valid credentials"))}
      #{Jason.encode!(failure_json("User logout", "session cleanup"))}
      """

      File.write!(jsonl_path, content)

      assert {:ok, failures} = Spex.parse_jsonl(jsonl_path)
      assert length(failures) == 2

      [first, second] = failures
      assert %Failure{} = first
      assert first.spex == "User login"
      assert second.spex == "User logout"
    end

    test "returns {:ok, []} for empty file", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "empty.jsonl")
      File.write!(jsonl_path, "")

      assert {:ok, []} = Spex.parse_jsonl(jsonl_path)
    end

    test "returns {:ok, []} when file doesn't exist", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "nonexistent.jsonl")

      assert {:ok, []} = Spex.parse_jsonl(jsonl_path)
    end

    test "decodes all failure fields correctly", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "full_failure.jsonl")

      failure_data = %{
        "type" => "failure",
        "spex" => "User authentication",
        "scenario" => "login with valid credentials",
        "steps" => [
          %{"type" => "Given", "description" => "user exists", "status" => "passed"},
          %{"type" => "When", "description" => "user logs in", "status" => "failed"}
        ],
        "error" => %{
          "message" => "Expected 100 but got 42",
          "file" => "test/spex/login_spex.exs",
          "line" => 25,
          "stacktrace" => [
            %{
              "module" => "ExUnit.Assertions",
              "function" => "assert",
              "arity" => 2,
              "file" => "lib/ex_unit/assertions.ex",
              "line" => 436
            }
          ],
          "left" => "42",
          "right" => "100"
        }
      }

      File.write!(jsonl_path, Jason.encode!(failure_data))

      assert {:ok, [failure]} = Spex.parse_jsonl(jsonl_path)

      assert %Failure{} = failure
      assert failure.spex == "User authentication"
      assert failure.scenario == "login with valid credentials"

      assert [step1, step2] = failure.steps
      assert %Step{} = step1
      assert step1.type == "Given"
      assert step1.description == "user exists"
      assert step1.status == "passed"

      assert %Step{} = step2
      assert step2.type == "When"
      assert step2.description == "user logs in"
      assert step2.status == "failed"

      assert %Error{} = failure.error
      assert failure.error.message == "Expected 100 but got 42"
      assert failure.error.file == "test/spex/login_spex.exs"
      assert failure.error.line == 25
      assert failure.error.left == "42"
      assert failure.error.right == "100"
      assert length(failure.error.stacktrace) == 1
    end

    test "returns {:error, _} for malformed JSON", %{tmp_dir: tmp_dir} do
      jsonl_path = Path.join(tmp_dir, "malformed.jsonl")
      File.write!(jsonl_path, "not valid json{{{")

      assert {:error, _} = Spex.parse_jsonl(jsonl_path)
    end

    test "parses real passing spex output from cached run" do
      # Use cached passing spex results from TestAdapter
      cached_jsonl = TestAdapter.spex_results_passing_cache_path()

      assert {:ok, failures} = Spex.parse_jsonl(cached_jsonl)
      # Passing tests should have no failures
      assert failures == []
    end

    test "parses real failing spex output from cached run" do
      # Use cached failing spex results from TestAdapter
      cached_jsonl = TestAdapter.spex_results_failing_cache_path()

      assert {:ok, failures} = Spex.parse_jsonl(cached_jsonl)
      # Should have at least one failure
      assert failures != []

      # Verify first failure has proper structure
      [failure | _] = failures
      assert %Failure{} = failure
      assert is_binary(failure.spex)
      assert is_list(failure.steps)

      # At least one step should have failed
      assert Enum.any?(failure.steps, &(&1.status == "failed"))

      # Should have error details
      assert %Error{} = failure.error
      assert is_binary(failure.error.message)
    end
  end

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defp failure_json(spex, scenario) do
    %{
      "type" => "failure",
      "spex" => spex,
      "scenario" => scenario,
      "steps" => [
        %{"type" => "Given", "description" => "some precondition", "status" => "passed"},
        %{"type" => "When", "description" => "some action", "status" => "failed"}
      ],
      "error" => %{
        "message" => "Assertion failed",
        "file" => "test/spex/test_spex.exs",
        "line" => 10,
        "stacktrace" => [],
        "left" => nil,
        "right" => nil
      }
    }
  end

  # ============================================================================
  # expand_directory_args/2 - directory args expand to their *_spex.exs files
  # ============================================================================

  describe "expand_directory_args/2" do
    test "expands a directory arg to its spex files", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "test/spex/story")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "criterion_1_spex.exs"), "")
      File.write!(Path.join(dir, "criterion_2_spex.exs"), "")
      File.write!(Path.join(dir, "not_a_spex.txt"), "")

      expanded = Spex.expand_directory_args(["test/spex/story"], tmp_dir)

      assert Enum.sort(expanded) == [
               "test/spex/story/criterion_1_spex.exs",
               "test/spex/story/criterion_2_spex.exs"
             ]
    end

    test "expands nested directories recursively", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "test/spex/story/nested")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "deep_spex.exs"), "")

      assert Spex.expand_directory_args(["test/spex/story"], tmp_dir) ==
               ["test/spex/story/nested/deep_spex.exs"]
    end

    test "leaves file args, flags, and unknown paths untouched", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "single_spex.exs")
      File.write!(file, "")

      args = ["single_spex.exs", "--trace", "no/such/path.exs"]
      assert Spex.expand_directory_args(args, tmp_dir) == args
    end

    test "keeps a directory with no spex files as-is (mix spex reports it loudly)", %{
      tmp_dir: tmp_dir
    } do
      dir = Path.join(tmp_dir, "empty_dir")
      File.mkdir_p!(dir)

      assert Spex.expand_directory_args(["empty_dir"], tmp_dir) == ["empty_dir"]
    end
  end
end
