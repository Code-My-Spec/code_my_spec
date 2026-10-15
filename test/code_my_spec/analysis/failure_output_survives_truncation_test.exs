defmodule CodeMySpec.Analysis.FailureOutputSurvivesTruncationTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Analysis
  alias CodeMySpec.Analysis.Runners

  @failure "  1) test receives a reply (Demo.BuilderTest)\n     test/demo/builder_test.exs:42\n     Assertion failed\n     left: :waiting\n     right: :ready\n"
  @summary "4000 tests, 1 failure"

  defp raw(output) do
    %{
      "exit_status" => 1,
      "execution_status" => "error",
      "stats" => %{},
      "diagnostics" => [],
      "output" => output
    }
  end

  test "summary and first failure location outrank a deliberate process crash" do
    output = "** (stop) :crashed\n" <> @failure <> @summary <> "\n"

    assert {:error, {:test_suite_did_not_run, 1, excerpt}} =
             Runners.from_raw("exunit", raw(output))

    assert excerpt =~ @summary
    assert excerpt =~ "1) test receives a reply (Demo.BuilderTest)"
    assert excerpt =~ "test/demo/builder_test.exs:42"
    refute excerpt =~ ":crashed"
  end

  test "harness and server retain the failure tail through both caps" do
    output =
      "Running ExUnit with seed: 42\n" <>
        String.duplicate("chatter\n", 20_000) <> @failure <> @summary

    harness_output = Analysis.cap(output)

    payload = %{
      raw(harness_output)
      | "execution_status" => "failure",
        "stats" => %{"tests" => 4000, "failures" => 1},
        "diagnostics" => [
          %{"file" => "test/demo/builder_test.exs", "line" => 42, "message" => "Assertion failed"}
        ]
    }

    assert {:ok, result} = Runners.from_raw("exunit", payload)

    assert result.output =~ "Running ExUnit with seed: 42"
    assert result.output =~ @failure
    assert result.output =~ @summary
    assert result.output == harness_output
    assert byte_size(result.output) <= 100_000
    assert [problem] = result.problems
    assert problem.file_path == "test/demo/builder_test.exs"
  end

  test "both retained boundaries stay valid and repeated caps preserve the result" do
    output = String.duplicate("a", 19_999) <> String.duplicate("🙂│", 20_000) <> @summary
    capped = Runners.cap(output)

    assert String.valid?(capped)
    assert byte_size(capped) <= 100_000
    assert String.starts_with?(capped, String.duplicate("a", 19_999))
    assert capped =~ @summary
    assert capped =~ "middle omitted"
    assert Runners.cap(capped) == capped
    assert Analysis.cap(output) == capped
    assert Jason.decode!(Jason.encode!(%{output: capped}))["output"] == capped
  end

  test "the server-only path retains the failure block after lengthy chatter" do
    output = String.duplicate(".", 120_000) <> "\n" <> @failure <> @summary

    payload = %{
      raw(output)
      | "execution_status" => "failure",
        "stats" => %{"tests" => 4000, "failures" => 1},
        "diagnostics" => [
          %{"file" => "test/demo/builder_test.exs", "line" => 42, "message" => "Assertion failed"}
        ]
    }

    assert {:ok, result} = Runners.from_raw("exunit", payload)
    assert result.output =~ @failure
    assert result.output =~ @summary
    assert byte_size(result.output) <= 100_000
  end

  test "a large failed transport payload still explains the suite result" do
    output =
      "** (stop) :crashed\n" <> String.duplicate(".", 120_000) <> "\n" <> @failure <> @summary

    assert {:error, {:test_suite_did_not_run, 1, excerpt}} =
             Runners.from_raw("exunit", raw(Analysis.cap(output)))

    assert excerpt =~ @summary
    assert excerpt =~ "test/demo/builder_test.exs:42"
    refute excerpt =~ ":crashed"
  end
end
