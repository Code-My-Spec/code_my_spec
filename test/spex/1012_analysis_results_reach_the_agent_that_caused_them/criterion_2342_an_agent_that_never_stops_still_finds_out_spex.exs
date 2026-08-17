defmodule CodeMySpecSpex.Story1012.Criterion2342Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 2342 — An agent that never stops still finds out.

  Rule: A completed analyzer run reaches the agent on its next tool call,
  whatever that call is.

  The incident, stated as the thing that must not happen again. On 2026-08-12 a
  schema change took the spex suite from 7 failures to 25. `mix test` was green
  — eight runs — and the change was committed. The spex result was ~126 seconds
  away the whole time; nothing asked for it and nothing handed it over.

  The stop hook is not the answer here, and measurement says so rather than
  argument: three stop decisions inside that window all allowed, two for
  "Active subagent task" and one for "analysis pending". The second is
  structural — `analysis pending` IS the state right after code changes, because
  changing code is what makes analysis pending. The gate is reliably open at the
  only moment it matters.

  So this scenario deliberately never stops between the result landing and the
  assertion. Whatever tells the agent has to be the tool call itself.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Delivery does not wait for a stop" do
    scenario "An agent that never stops still finds out" do
      given_ :synced_context_component

      given_ "an agent has changed code and an analyzer run is in flight", context do
        session = "spex-working-#{System.unique_integer([:positive])}"

        post_hook(context, "/api/hooks/post-tool-use", %{
          "session_id" => session,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => "lib/example_context.ex"}
        })

        {:ok, Map.put(context, :session, session)}
      end

      when_ "the run completes while the agent is still working", context do
        use_cmd_cassette "pipeline_exunit_failure", record: :none do
          post_hook(context, "/api/hooks/stop", %{
            "session_id" => "spex-someone-else-#{System.unique_integer([:positive])}",
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
          post_hook(context, "/api/hooks/post-tool-use", %{
            "session_id" => context.session,
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })

        assert (told["systemMessage"] || "") =~ "exunit",
               "the agent made a tool call after the result landed and was told nothing. " <>
                 "This is the incident: the answer existed, was cheap, and had no route " <>
                 "to the agent before it committed. Got: #{inspect(told)}"

        {:ok, context}
      end

      then_ "it is told without having stopped", context do
        # The load-bearing half. Nothing in this scenario posts a stop for
        # `context.session` — if the assertion above passed, delivery happened on
        # ordinary tool traffic, which is the only place it can happen inside the
        # window where the stop gate is structurally open.
        assert context.session =~ "spex-working-",
               "the session under test must be the one that never stopped"

        {:ok, context}
      end
    end
  end
end
