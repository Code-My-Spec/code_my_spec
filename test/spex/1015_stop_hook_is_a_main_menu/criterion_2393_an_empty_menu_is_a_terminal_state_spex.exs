defmodule CodeMySpecSpex.Story1015.Criterion2393Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2393 — An empty menu is a terminal state.

  The rule:

  > An agent with no work in any class is allowed to stop.

  The half of the menu that says nothing. When questions, problems, issues and
  requirements are all empty, the answer is that there is nothing to do — and
  the hook has to be willing to say so.

  John's account of why is the reason this criterion exists: the framework queue
  emptied, nothing said so, and the agent kept sweeping surfaces looking for
  work rather than stopping. The last of those returned ~900 "orphan components"
  that are not defects. A menu with no terminal state does not produce rest; it
  produces invented work.

  ## The precondition is the hard part, and two attempts got it wrong

  First on `:synced_context_component`, which leaves requirements unsatisfied —
  the Given was false and the scenario passed anyway, because nothing rendered a
  directive yet. Then on `:synced_context_in_satisfied_project`, which is worse
  in an interesting way: it calls `FullSatisfactionFixtures.apply` and *then*
  creates a component, a story and its rules, so it satisfies everything and
  immediately adds two fresh requirements. It reads like the right given and is
  the opposite of it.

  So this uses the fixture directly, the way criterion 5120 does for the same
  terminal state on the continuous-mode branch. Nothing else is set up, because
  anything set up here is work the menu would then report.

  And the Given is now *asserted* rather than trusted (issue `214d8050`). Both
  wrong preconditions above passed, and they passed for the reason every refute-
  only scenario does: every claim here is an absence, and a graph with work left
  in it produces the same silence in the `reason` field as a graph with none.
  `get_next_requirement` distinguishes them, and distinguishes the third case
  too — an unsynced project answers `sync_required` rather than
  "All requirements satisfied", which is not this criterion's premise either.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`. No cassette and no
  `test_output_files`: with no changed files there is nothing for an analyzer to
  run, and staging output would be staging the very state the criterion says is
  absent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent with nothing to do is allowed to stop" do
    scenario "no class of work has anything for this working copy" do
      given_ "every requirement in the graph is satisfied, so no class is live", context do
        context = FullSatisfactionFixtures.apply(context)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, next, _frame} = GetNextRequirement.execute(%{}, frame)

        assert response_text(next) =~ "All requirements satisfied",
               "the premise is false, and every assertion below is an absence that " <>
                 "a graph with work left in it satisfies just as well. Two earlier " <>
                 "preconditions were wrong exactly here and passed anyway. " <>
                 "Got: #{response_text(next)}"

        {:ok, context}
      end

      given_ "a session exists for this working copy", context do
        session_id = "spex-2393-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent attempts to stop", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook allows the stop", context do
        refute context.response["decision"] == "block",
               "an empty menu must be a terminal state; a hook that cannot say " <>
                 "\"nothing to do\" produces invented work instead of rest. Got: " <>
                 "#{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the response directs the agent to no tool call", context do
        reason = context.response["reason"] || ""

        refute reason =~ "get_next_requirement",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        refute reason =~ "list_problems",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        refute reason =~ "list_issues",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        refute reason =~ "check_answer",
               "nothing is outstanding, so nothing should be recommended. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end
end
