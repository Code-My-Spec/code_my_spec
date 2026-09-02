defmodule CodeMySpecSpex.Story1042.Criterion3050Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3050 — Being alerted mid-work does not cost the agent its stop
  decision.

  Rule: The alert and the stop decision are separate deliveries; receiving one
  does not suppress the other.

  This started as a red card. Two deliveries were being designed at once — this
  story's alert, and story 1043's stop decision — and the worry was that an
  internal agent would end up told twice about one set of problems, so one of
  them should own it.

  The answer was that they are not duplicates, and the evidence is that the
  external agent already receives both: `PostToolUse` alerts it mid-work, and
  the stop hook decides at turn end. Nobody has ever complained, because they
  answer different questions at different moments — "something landed, and you
  are still working" against "you are trying to stop, and here is what is
  outstanding and what to do next".

  So the risk is not duplication, it is an implementer resolving the perceived
  duplication by making the alert suppress the decision. That is what this
  forbids, and it is why the card became a rule rather than being closed.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The alert and the stop decision are separate deliveries; receiving one does not suppress the other" do
    scenario "Being alerted mid-work does not cost the agent its stop decision" do
      given_ "an agent under Alloy alerted that a run landed with problems", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "compiler",
          message: "** (SyntaxError) missing terminator: end",
          file_path: "lib/example_context.ex"
        })

        context = Map.put(context, :agent_id, running_agent(context))

        assert {:ok, alerted} = Fixtures.run_script("return 1", agent_context(context))

        assert alerted =~ "compiler",
               "the agent was never alerted, so this scenario never reaches its subject"

        {:ok, Map.put(context, :alerted, alerted)}
      end

      when_ "a stop decision is produced for that working copy", context do
        # The stop hook, because the internal turn-end seam is story 1043's to
        # build and does not exist yet. That is not a dodge: what this criterion
        # guards against is the alert *consuming* the findings — marking them
        # delivered so the decision that follows has nothing left to say — and
        # the decision is produced from the same problems whichever agent asks
        # for it. If the alert empties them, this goes quiet too.
        decision =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
            "session_id" => "a-session-that-stops"
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :decision, decision["reason"] || "")}
      end

      then_ "it is still given the stop decision", context do
        decision = context.decision

        assert decision =~ "compiler", """
        The agent was alerted mid-work and then allowed to stop in silence,
        because something treated the alert as having already said it. They are
        different messages at different moments: one says work landed while you
        are working, the other says you are trying to leave and here is what is
        outstanding. An external agent gets both and always has.

        Got: #{inspect(decision)}
        """

        {:ok, context}
      end
    end
  end
end
