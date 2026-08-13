defmodule CodeMySpecSpex.Story1012.Criterion2349Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2349 — An answer that predates the fix.

  Rule: The alert says how old the answer is.

  The failure surface for the age, and the one that costs real time. An agent
  fixes the cause; no run has completed since; the outstanding count is still
  there. Without the age it reads as a verdict on the fix, and the agent either
  re-fixes finished work or stops trusting a result that was correct.

  Both wrong turns were taken on 2026-08-13. The stop gate reported four credo
  findings already corrected, and only its own "stale, last ran 4m ago" stopped
  a second round of edits to four files that were already clean.

  The corollary matters as much as the age itself: a fix with no run behind it
  must not be reported as passing. Silence about green (criterion 2346) is what
  makes that safe — there is no "your fix worked" to issue prematurely.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An outstanding count is not a verdict on the fix" do
    scenario "An answer that predates the fix" do
      given_ :synced_context_component

      given_ "an agent has been told an analyzer is failing", context do
        session = "spex-fixing-#{System.unique_integer([:positive])}"

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
               "the premise failed: nothing was reported as failing"

        {:ok, Map.put(context, :session, session)}
      end

      when_ "it fixes the cause and no run has completed since", context do
        # The edit lands; no analyzer runs. This is the window the criterion is
        # about, and it is the ordinary state right after any change.
        :ok =
          Environments.write_file(
            context.environment,
            "lib/example_context.ex",
            "defmodule ExampleContext do\n  @moduledoc false\n  def fixed, do: :ok\nend\n"
          )

        hook("/api/hooks/post-tool-use", context, %{
          "session_id" => context.session,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => "lib/example_context.ex"}
        })

        {:ok, context}
      end

      then_ "it is not told the analyzer is passing", context do
        after_fix = hook("/api/hooks/post-tool-use", context, tool_call(context.session))
        message = after_fix["systemMessage"] || ""

        refute message =~ ~r/passing|green|clean|resolved|fixed/i,
               "the agent was told its fix worked, on no evidence — no run has " <>
                 "completed since the edit. A verdict issued ahead of the run is worse " <>
                 "than none: it is confidently wrong at the exact moment the agent is " <>
                 "deciding whether to move on. Got: #{message}"

        {:ok, context}
      end

      then_ "the failure it can still see is marked as older than its fix", context do
        # Asked from a session that has not been told yet, so the alert is
        # guaranteed to be spoken rather than deduplicated. The agent that made
        # the fix is silent by design (criterion 2345), and branching on whether
        # it happened to speak would make this assert whatever the run did.
        fresh = "spex-fresh-#{System.unique_integer([:positive])}"
        message = hook("/api/hooks/post-tool-use", context, tool_call(fresh))["systemMessage"]

        assert message =~ "exunit",
               "the outstanding failure vanished from the alert without a run having " <>
                 "replaced it. Nothing has re-analysed the tree, so it is still the " <>
                 "current answer. Got: #{inspect(message)}"

        assert message =~ ~r/ago/,
               "the outstanding failure was reported with no indication of when it was " <>
                 "computed. An agent that has just fixed the cause reads that as a " <>
                 "verdict on the fix and either re-fixes finished work or distrusts a " <>
                 "correct result — both happened on 2026-08-13. Got: #{message}"

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
