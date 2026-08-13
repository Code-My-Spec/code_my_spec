defmodule CodeMySpecSpex.Story1012.Criterion2346Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2346 — A clean run says nothing.

  Rule: An agent is told once, and again only when new problems appear.

  "Your fix worked" is real information and it is still not worth a line. Runs
  land constantly; announcing the green ones is a steady drip that teaches the
  model to skip the channel, and then the red one arrives in a place nobody
  reads. The PM's call, and the cheaper half of the trade — an agent that wants
  to know can ask, and asking is one tool call.

  Surface: the PostToolUse hook after a green run, and `list_problems` for the
  agent that does want to check.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Problems.Tools.ListProblems

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Good news is not announced" do
    scenario "A clean run says nothing" do
      given_ :synced_context_component

      given_ "an agent has been told about a failing analyzer", context do
        session = "spex-fixer-#{System.unique_integer([:positive])}"

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

        told = hook("/api/hooks/post-tool-use", context, tool_call(session))

        assert (told["systemMessage"] || "") =~ "exunit",
               "the premise failed: nothing was reported as failing, so a later " <>
                 "silence would prove nothing"

        {:ok, Map.put(context, :session, session)}
      end

      when_ "it fixes the cause and the next run lands clean", context do
        use_cmd_cassette "clean", record: :none do
          hook("/api/hooks/stop", context, %{
            "session_id" => context.session,
            "test_output_files" => %{
              "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl")
            }
          })
        end

        {:ok, context}
      end

      then_ "it is not told that the run was green", context do
        after_fix = hook("/api/hooks/post-tool-use", context, tool_call(context.session))
        message = after_fix["systemMessage"] || ""

        refute message =~ ~r/green|passing|clean|resolved|fixed/i,
               "the clean run was announced. Every green run announced is a line the " <>
                 "model learns to skip, and the red one then arrives somewhere nobody " <>
                 "reads. Got: #{message}"

        {:ok, context}
      end

      then_ "asking for the problems shows them gone", context do
        {:reply, response, _frame} =
          ListProblems.execute(
            %{source: "exunit"},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        refute response_text(response) =~ "example_context_test",
               "the failing test is still listed after a clean run replaced it. " <>
                 "Silence is only acceptable because asking gives the current answer; " <>
                 "a stale answer on request makes the silence a lie."

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

  defp tool_call(session_id) do
    %{
      "session_id" => session_id,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => "lib/example_context.ex"}
    }
  end
end
