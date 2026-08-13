defmodule CodeMySpecSpex.Story1012.Criterion2348Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2348 — The age is on the line.

  Rule: The alert says how old the answer is.

  "5 spex failing" is a claim about a tree the agent cannot identify. Analysis
  is async, so the run behind that count may predate the last three edits, and
  without the age there is no way to tell a verdict on the current work from a
  verdict on work already replaced.

  Story 988 keeps the verdict honest; this makes its honesty legible at the
  point of use. The stop hook already does exactly this and it demonstrably
  works — "credo (4) — stale, last ran 4m ago" is what stopped an agent
  re-fixing four files that were already correct.

  Surface: the PostToolUse hook.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A count without a timestamp is a claim about an unknown tree" do
    scenario "The age is on the line" do
      given_ :synced_context_component

      given_ "an analyzer run has finished", context do
        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          hook("/api/hooks/stop", context, %{
            "session_id" => "spex-seed-#{System.unique_integer([:positive])}",
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
              "compile" => Path.expand(Path.join(@fixture_dir, "compile.jsonl")),
              "exunit" => Path.expand(Path.join(@fixture_dir, "exunit.json"))
            }
          })
        end

        {:ok, context}
      end

      when_ "the agent is told about its failures", context do
        told =
          hook("/api/hooks/post-tool-use", context, %{
            "session_id" => "spex-asking-#{System.unique_integer([:positive])}",
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })

        {:ok, Map.put(context, :message, told["systemMessage"] || "")}
      end

      then_ "it is told how many, from which analyzer, and how long ago the run finished",
            context do
        assert context.message =~ "exunit",
               "the alert did not name the analyzer. Got: #{context.message}"

        assert context.message =~ ~r/\d/,
               "the alert carried no count. Got: #{context.message}"

        assert context.message =~ ~r/ago|just now|seconds?|minutes?|hours?/i,
               "the alert gave a count with no age. That is a claim about a tree the " <>
                 "agent cannot identify: analysis is async, so this run may predate " <>
                 "the last three edits, and nothing here says which. " <>
                 "Got: #{context.message}"

        {:ok, context}
      end
    end
  end

  defp hook(path, context, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, path, params)
    |> Phoenix.ConnTest.json_response(200)
  end
end
