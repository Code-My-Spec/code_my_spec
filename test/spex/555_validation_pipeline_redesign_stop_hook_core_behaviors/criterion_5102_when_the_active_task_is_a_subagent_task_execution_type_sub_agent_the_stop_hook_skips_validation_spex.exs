defmodule CodeMySpecSpex.Story555.Criterion5102Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5102 — When the active task is a subagent task
  (execution_type: :sub_agent), the stop hook skips validation
  entirely and allows the stop immediately.

  StopController's `decide/6` short-circuits via
  `has_active_subagent_task?/1` before validation even runs. No
  pipeline, no compile, no analyzers — so no cassette is needed. If
  the short-circuit broke and the pipeline tried to run `mix compile`,
  it would blow up because there's no cassette in scope.

  Session + task created via `Fixtures.session_with_task_fixture/3`.
  These kinds of tasks originate server-side (orchestrators create
  subagent tasks; agents don't start them through the local contract),
  so the fixture bridge is the right abstraction — not an agent-driven
  given.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Subagent task short-circuits the stop hook" do
    scenario "active subagent task → allow with no pipeline" do
      given_ :synced_context_component

      given_ "a session has an active subagent task", context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        session =
          Fixtures.session_with_task_fixture(
            context.scope,
            %{external_conversation_id: external_id},
            %{execution_type: :sub_agent}
          )

        {:ok, Map.merge(context, %{session: session, external_id: external_id})}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.external_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed with the empty signal", context do
        assert context.response == %{},
               "subagent short-circuit must produce empty allow, got: #{inspect(context.response)}"

        :ok
      end
    end
  end
end
