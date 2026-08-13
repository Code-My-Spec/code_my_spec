defmodule CodeMySpecSpex.Story1012.Criterion2343Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2343 — A reading turn is told too.

  Rule: A completed analyzer run reaches the agent on its next tool call,
  whatever that call is.

  Scoping delivery to edits would reintroduce a "which tools count" judgement,
  which is the same species of question as "which files count" — and that one
  turned the stop gate into a no-op. It would also go silent through exactly the
  stretches where an agent is reasoning about what it just did rather than
  typing, which is when a landed result is most worth having.

  The incident supports it directly: the file edited (`story.ex`) was nowhere
  near the four stories whose spex broke.

  Surface: the PostToolUse hook on a read.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every tool call carries it, not only the ones that write" do
    scenario "A reading turn is told too" do
      given_ :synced_context_component

      given_ "an agent is reading rather than editing", context do
        {:ok, Map.put(context, :session, "spex-reader-#{System.unique_integer([:positive])}")}
      end

      when_ "an analyzer run completes", context do
        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          hook("/api/hooks/stop", context, %{
            "session_id" => "spex-other-#{System.unique_integer([:positive])}",
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
              "compile" => Path.expand(Path.join(@fixture_dir, "compile.jsonl")),
              "exunit" => Path.expand(Path.join(@fixture_dir, "exunit.json"))
            }
          })
        end

        {:ok, context}
      end

      then_ "the agent is told on its next tool call", context do
        told =
          hook("/api/hooks/post-tool-use", context, %{
            "session_id" => context.session,
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })

        assert (told["systemMessage"] || "") =~ "exunit",
               "a reading turn was told nothing. An agent that spends a stretch reading " <>
                 "is reasoning about what it just did, which is when a landed result is " <>
                 "most worth having. Got: #{inspect(told)}"

        {:ok, context}
      end

      then_ "the call being a read rather than a write makes no difference", context do
        # Same result, different tool. If these two ever disagree there is a
        # "which tools count" rule in the delivery path, and that is a place a
        # finding can hide.
        grep =
          hook("/api/hooks/post-tool-use", context, %{
            "session_id" => "spex-grepper-#{System.unique_integer([:positive])}",
            "tool_name" => "Grep",
            "tool_input" => %{"pattern" => "defmodule"}
          })

        assert (grep["systemMessage"] || "") =~ "exunit",
               "a Grep was treated differently from a Read. Whichever tool is the " <>
                 "exception becomes the blind spot. Got: #{inspect(grep)}"

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
