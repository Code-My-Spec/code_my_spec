defmodule CodeMySpecSpex.Story555.Criterion5103Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5103 — When the active task has validation_type: :manual,
  the stop hook skips validation and task evaluation and allows the
  stop.

  StopController's `decide/6` short-circuits via
  `has_active_manual_task?/1` (which consults `Session.active_task`)
  before validation runs. No pipeline, no cassette needed — if the
  short-circuit broke and the pipeline tried to run, the test would
  blow up on a missing cassette.

  Manual-validation tasks represent work a human (not the agent)
  verifies — an orchestrator creates them; agents don't self-start
  them through the local contract. Using the Fixtures bridge matches
  the real origin.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Manual-validation task short-circuits the stop hook" do
    scenario "active manual task → allow with no pipeline and no eval" do
      given_ :synced_context_component

      given_ "a session has an active manual-validation task", context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        session =
          Fixtures.session_with_task_fixture(
            context.scope,
            %{external_conversation_id: external_id},
            %{validation_type: :manual}
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
               "manual-validation short-circuit must produce empty allow, got: #{inspect(context.response)}"

        :ok
      end
    end
  end
end
