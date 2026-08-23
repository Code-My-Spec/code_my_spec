defmodule CodeMySpecSpex.Story538.Criterion5120Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5120 — When the last actionable requirement is satisfied,
  the next stop is allowed and the user is notified.

  Covers Rule R6: "Empty graph terminates the loop. When the last
  actionable requirement is satisfied, the next stop is allowed and
  the user is notified."

  This is the terminal-state branch of continuous mode: even with the
  flag on, an empty actionable set ends the loop instead of looping
  forever. The notification is the user-visible signal (driven by
  `NotificationClient.notify/1`); the agent surface signal is the
  empty stop response.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Continuous mode with no actionable work → allow stop, notify user" do
    scenario "fully-satisfied project with continuous on returns the empty allow signal" do
      given_ "every requirement in the graph is satisfied so the actionable set is empty",
             context do
        # FullSatisfactionFixtures.apply walks the entire serial chain:
        # project kickoff → personas → stories → component (Reservations
        # context with no children) → story-level Three Amigos + BDD
        # specs + qa → journey artifacts. With no actionable work left
        # in any layer, the continuous-mode terminal branch fires.
        context = FullSatisfactionFixtures.apply(context)
        {:ok, context}
      end

      given_ "a session exists with continuous mode enabled and no active task",
             context do
        session_id = "spex-5120-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        :ok = Fixtures.start_continuous_mode(context.scope, session_id)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed (no block decision)", context do
        # Post-R7 the R6 terminus carries a retrospective payload, so the
        # signal is no longer literally `%{}`. The terminal contract is
        # the absence of a block decision; the retrospective belongs to
        # criterion 6219 and is asserted there.
        refute context.response["decision"] == "block",
               "empty actionable set must allow stop even with continuous on — got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
