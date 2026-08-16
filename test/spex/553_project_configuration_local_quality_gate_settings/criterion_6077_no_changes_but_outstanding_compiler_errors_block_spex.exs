defmodule CodeMySpecSpex.Story553.Criterion6077Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 6077 — When the agent makes no file changes during the
  task but there are outstanding compiler error problems in the DB
  from a previous run, the stop hook still blocks. The blocking
  check always runs and consults the problems table even when no
  pipeline runs this turn.

  Setup shortcut: this scenario tests the blocking-check decision,
  not the upstream production of the compiler problem. The compile-
  error production path is covered end-to-end by 555/5099. Per
  priv/knowledge/bdd/spex/boundaries.md (anti-pattern note), seeding
  the problem directly via `Fixtures.problem_fixture/2` is the
  acknowledged shortcut here.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Outstanding compile error blocks a no-changes stop" do
    scenario "compiler error problem in DB, no file changes this turn, stop blocks" do
      given_ :synced_context_component

      given_ "an outstanding compiler error problem exists in the DB",
             context do
        Fixtures.problem_fixture(context.scope, %{
          severity: :error,
          source_type: :static_analysis,
          source: "compiler",
          file_path: "lib/example_context.ex",
          line: 1,
          message: "syntax error before: ')'",
          category: "compile",
          rule: "Compiler.Syntax"
        })

        {:ok, context}
      end

      when_ "the stop hook fires with no additional file writes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked despite no pipeline running this turn", context do
        assert context.response["decision"] == "block",
               "outstanding compile error must block the stop even with no changes, got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the block reason references the outstanding compiler error",
           context do
        reason = context.response["reason"]

        assert is_binary(reason),
               "expected a reason string, got: #{inspect(context.response)}"

        assert reason =~ ~r/compil/i,
               "expected the reason to name the compiler problem, got: #{reason}"

        {:ok, context}
      end
    end
  end
end
