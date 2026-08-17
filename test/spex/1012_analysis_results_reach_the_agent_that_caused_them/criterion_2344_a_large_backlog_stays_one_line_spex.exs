defmodule CodeMySpecSpex.Story1012.Criterion2344Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2344 — A large backlog stays one line.

  Rule: The alert names the analyzer and the count; the findings themselves are
  pulled on demand.

  This working copy holds 407 credo findings. Pasting findings into every tool
  result would bury the turn in noise the model learns to skip — which costs the
  signal a second time, and more permanently than never sending it: a channel
  that is usually noise gets ignored even when it is not.

  So the alert is a notification, not a report. Push the fact, pull the detail.

  Surface: the PostToolUse hook for the alert, and `list_problems` for the
  detail an agent asks for.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Problems.Tools.ListProblems

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Push the fact, pull the detail" do
    scenario "A large backlog stays one line" do
      given_ :synced_context_component

      given_ "the working copy holds findings", context do
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

      when_ "the agent is told that a run has landed", context do
        told =
          hook("/api/hooks/post-tool-use", context, %{
            "session_id" => "spex-told-#{System.unique_integer([:positive])}",
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })

        {:ok, Map.put(context, :message, told["systemMessage"] || "")}
      end

      then_ "it is told how many and from which analyzer", context do
        assert context.message =~ "exunit",
               "the alert did not name the analyzer, so the agent cannot tell a test " <>
                 "failure from a lint finding without asking. Got: #{context.message}"

        assert context.message =~ ~r/\d/,
               "the alert carried no count. Without one there is no way to judge " <>
                 "whether this is one regression or a broken build. " <>
                 "Got: #{context.message}"

        {:ok, context}
      end

      then_ "the findings themselves are not in the message", context do
        refute context.message =~ "example_context",
               "a file path reached the alert. One path is one path; the rule exists " <>
                 "because 407 of them arrive on every tool call and the model learns " <>
                 "to skip the line. Got: #{context.message}"

        # One line. Not "short-ish" — it rides on every tool call in every turn,
        # so the budget is a sentence and the PM set it deliberately.
        assert String.length(context.message) < 200,
               "the alert is a notification, not a report. Got " <>
                 "#{String.length(context.message)} characters: #{context.message}"

        {:ok, context}
      end

      then_ "the agent can ask for them", context do
        {:reply, response, _frame} =
          ListProblems.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        assert response_text(response) =~ "example_context",
               "the detail the alert deliberately withheld was not available on " <>
                 "request. Withholding is only acceptable because asking is cheap; " <>
                 "without the pull the push is censorship."

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
