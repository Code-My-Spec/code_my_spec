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

  ## What this asserts, and what it leaves to story 1043

  The suppression would happen one way: the alert consuming the findings —
  marking them delivered, or resolving them — so that whatever reads them next
  has nothing to report. That is checked here, by asking again after the agent
  has been alerted.

  It does **not** drive an internal stop decision, because there is no seam to
  drive one from: a turn ending does not enqueue analysis today, which is story
  1043's first rule. Approximating it through the stop hook was tried and
  abandoned — a stop needs an active task, an available analyzer and an
  attributed edit before it will speak, and this spec went red on those instead
  of on its own subject three times running. A red spec that fails for a reason
  unrelated to its criterion misdirects whoever has to turn it green, which is
  worse than one that asserts less.

  So the half that can be true today is asserted today, and the interaction with
  a real internal stop decision belongs on 1043, where the seam it needs is
  being built.
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

      when_ "the findings are asked for again, by the surface a decision reads", context do
        # Delivered to a second agent rather than driven through a stop, and the
        # reduction is deliberate — see the moduledoc. A stop needs an active
        # task, an available analyzer and an attributed edit before it will
        # speak, and a spec red because one of those was missing would be red
        # about the hook's preconditions rather than about this criterion.
        told =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(
            CodeMySpecLocalWeb.Endpoint,
            :post,
            "/api/hooks/post-tool-use",
            %{"session_id" => "a-later-reader", "tool_name" => "Read"}
          )
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :later, told["systemMessage"] || "")}
      end

      then_ "they are still outstanding, so a decision would still have them", context do
        assert context.later =~ "compiler", """
        The findings did not survive the alert. Something treated telling the
        agent as having dealt with them — marked them delivered, or resolved
        them — so the next thing to ask has nothing to report. A stop decision
        reads the same problems, and it would fall silent for the same reason.

        Got: #{inspect(context.later)}
        """

        {:ok, context}
      end
    end
  end
end
