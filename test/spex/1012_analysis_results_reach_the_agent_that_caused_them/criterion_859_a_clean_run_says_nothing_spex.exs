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
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpec.McpServers.Problems.Tools.ListProblems

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Good news is not announced", criterion: 859 do
    scenario "A clean run says nothing" do
      given_ :synced_context_component

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "an agent has been told about a failing analyzer", context do
        session = "spex-fixer-#{System.unique_integer([:positive])}"

        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(
          context,
          "compiler",
          Path.expand(Path.join(@fixture_dir, "compile.jsonl"))
        )

        HarnessHooks.land_analysis(
          context,
          "exunit",
          Path.expand(Path.join(@fixture_dir, "exunit.json"))
        )

        HarnessHooks.post_hook(context, "stop", %{
          "session_id" => "spex-seed-#{System.unique_integer([:positive])}"
        })

        told = post_hook(context, "/api/hooks/post-tool-use", tool_call(session))

        assert (told["systemMessage"] || "") =~ "exunit",
               "the premise failed: nothing was reported as failing, so a later " <>
                 "silence would prove nothing"

        {:ok, Map.put(context, :session, session)}
      end

      when_ "it fixes the cause and the next run lands clean", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        # The suite that failed, run again and passing.
        HarnessHooks.land_analysis(context, "exunit")

        HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session})

        {:ok, context}
      end

      then_ "it is not told that the run was green", context do
        after_fix = post_hook(context, "/api/hooks/post-tool-use", tool_call(context.session))
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

  defp tool_call(session_id) do
    %{
      "session_id" => session_id,
      "tool_name" => "Read",
      "tool_input" => %{"file_path" => "lib/example_context.ex"}
    }
  end
end
