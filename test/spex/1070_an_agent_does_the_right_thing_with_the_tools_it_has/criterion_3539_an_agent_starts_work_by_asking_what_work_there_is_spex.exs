defmodule CodeMySpecSpex.Story1070.Criterion3539Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3539 — An agent starts work by asking what work there is.

  Rule: An agent claims work before it does the work.

  The first thing every agent does, and the one nothing has ever checked. The
  whole harness rests on it: the graph decides what is next, `start_task`
  records who is on it, and the stop hook evaluates what came back. An agent
  that picks its own work instead gets none of that — two agents land on the
  same requirement, and the one that finishes has nothing to close.

  ## Why this is measured rather than asserted

  The agent is the user here and the chat is the surface, so the only honest
  question is what a real agent, on a real first turn, actually calls. That is
  non-deterministic, which is why the criterion states a rate: nine runs in ten.

  A single green run would say the behaviour is *possible*. The rate says
  whether it is reliable, and a rate in the middle says the prompt is
  ambiguous — see `CodeMySpecSpex.AgentEvalHelpers.assert_rate/2`, which
  reports that as the finding rather than as a flake.

  ## Why `:eval`

  Ten fresh agents, each taking real turns against a real model. Minutes, not
  milliseconds. Excluded from every ordinary run and from the promote gate;
  `mix cms.eval` is the switch. Run it when a role brief, a system prompt or a
  tool list changes, because that is when this answer can have moved.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers
  import CodeMySpecSpex.SharedGivens

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :eval
  # `CodeMySpecSpex.Case` sets three minutes, which is right for a spex that
  # drives a surface and far too short for one that drives ten agents.
  @moduletag timeout: CodeMySpecSpex.AgentEvalHelpers.eval_timeout()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent claims work before it does the work" do
    scenario "An agent starts work by asking what work there is" do
      # A satisfied project, deliberately. With the project chain outstanding
      # every role is offered the same project-level work, which is a real
      # answer and not the one this criterion is about — the question is what an
      # agent does when there is component work waiting for its own role.
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3539")}
      end

      when_ "a fresh agent takes its first turn, ten times over", context do
        measured =
          measure("An agent starts work by asking what work there is", fn _run ->
            observe(context, [role: "coding"], fn agent ->
              called_in_order?(context, agent, "get_next_requirement", "start_task")
            end)
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "it asks what its work is, and claims it, before doing anything", context do
        assert_rate(context.measured, 0.9)

        {:ok, context}
      end
    end
  end
end
