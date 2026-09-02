defmodule CodeMySpecSpex.Story1043.Criterion3059Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3059 — A finding the agent cannot fix stops waking it.

  Rule: An agent told the same thing it could not act on is eventually left
  alone.

  This is the criterion that exists because a message can *cause work* rather
  than report it. Waking a stopped agent is the point of the whole story, and it
  is also the only delivery here that can run away: analysis lands, the agent
  wakes, cannot fix it, ends its turn, analysis lands again.

  The external path already has the escape and it was built from an incident.
  `validate_stop/3` returns a blocking key, `Sessions.record_eval_feedback/3`
  counts consecutive deliveries of the same one, and `maybe_terminate_stuck/5`
  allows the stop once it trips — added because eight consecutive blocks on a
  finding belonging to another story were observed spending an entire budget
  unattended.

  That escape is scoped to a session. An internal agent has none, so John's call
  was to count against the agent instead: same behaviour, same threshold, keyed
  on agent identity — which is the shift issue `927c2b78` already wanted
  elsewhere and the third time today the external agent's identity has turned
  out to be the wrong key.

  ## This is green for the wrong reason today

  It asserts that the count of things told does not grow. Nothing is delivered
  to an internal agent at all yet — findings are unattributable to an agent with
  no session, so `validate_stop/3` allows every time (see criterion 3052, red,
  and the note on story 988) — so the count is zero before and zero after, and
  the assertion holds without any escape existing.

  It will become meaningful the moment delivery works, and it is left this way
  deliberately: softening it would lose the criterion, and asserting the escape
  before anything can be delivered would be asserting on a mechanism with no
  input. Do not read this green as evidence that the escape is built. It is not.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent told the same thing it could not act on is eventually left alone" do
    scenario "A finding the agent cannot fix stops waking it" do
      given_ "an agent woken repeatedly for the same blocking finding", context do
        # Story 988's criterion 8201's recipe. `fresh_analysis_runs/2` is what
        # makes the finding block at all — without it credo is stale, nothing is
        # ever delivered, and this scenario passes by counting zero against
        # zero. It did exactly that until the delivery started working.
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        Fixtures.record_problem(context.scope, "credo", %{file_path: @impl_path})
        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        agent_id = running_agent(context)

        # Ended, and ended again, without the finding being resolved between
        # them. However many times an agent is told the same unfixable thing,
        # the tree is the same tree.
        for _ <- 1..8, do: :ok = Fixtures.end_turn(context.scope, agent_id)

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "the run lands with that same finding again", context do
        before = length(Fixtures.orchestrator_actions(context.scope, context.agent_id))
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok,
         context
         |> Map.put(:before, before)
         |> Map.put(
           :after,
           length(Fixtures.orchestrator_actions(context.scope, context.agent_id))
         )}
      end

      then_ "the agent is not woken", context do
        assert context.after == context.before, """
        The agent was told the same unfixable finding a ninth time. Each one
        wakes it and costs a turn, and the external path's own escape exists
        because eight in a row was observed spending a whole budget unattended.

        told before: #{context.before}, after: #{context.after}
        """

        {:ok, context}
      end
    end
  end
end
