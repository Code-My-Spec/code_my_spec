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

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
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

  # The exact text `Agents.Work` sends with an admitted turn.
  defp turn_prompt do
    "Eligible work is available. Call get_next_requirement to see it, then " <>
      "claim it with start_task. No task has been selected or assigned for you."
  end

  spex "An agent claims work before it does the work" do
    scenario "An agent starts work by asking what work there is" do
      # Project-level work for the main role, which is what an agent on a
      # harnessed checkout can actually be offered.
      #
      # This wanted component work for the coding role, on the reasoning that
      # project-level work is offered to everyone and is not the question. That
      # premise cannot be built here. `given_a_harnessed_checkout/2` makes an
      # empty temp directory, components are projections of files, and a
      # vantage with no files has no components — so `implementation_file`
      # cannot be actionable at the copy the agent runs on, whatever the
      # fixture does at its own copy. Measured 2026-09-20: at the agent's
      # checkout the actionable set was `coding: []`, `main:
      # ["technical_strategy"]`, `product: []`, `qa: []`.
      #
      # The criterion is about conduct and does not name a role — an agent asks
      # what its work is and claims it before doing anything, whichever agent it
      # is. So it is measured where work exists rather than where it cannot.
      given_ :synced_context_in_satisfied_project

      given_ "the satisfaction chain finished before anything reads the graph", context do
        # `FullSatisfactionFixtures.apply/1` leaves recomputes queued, and
        # `GraphWatcher` debounces them. Without waiting here the run measured a
        # different project each time: one pass left `main: ["technical_strategy"]`
        # — the project chain still incomplete — and the next left
        # `["bdd_specs_passing"]`, the chain finished and story work next. A
        # criterion whose premise is a different shape on each run is measuring
        # the fixture.
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3539")}
      end

      given_ "the graph settled at the agent's own checkout", context do
        # `observe/3` settles both vantages to a fixed point before every turn
        # request, so the frontier is the same when the turn is granted and when
        # the agent reads it. Kept as its own step because the premise this
        # criterion rests on is that there *is* claimable work — if the settle
        # ever stops being enough, the failure belongs here and not in the
        # measurement.
        :ok = Fixtures.settle_graph(context.scope)
        :ok = Fixtures.settle_graph(%{context.scope | active_working_copy_id: context.copy_id})

        {:ok, context}
      end

      when_ "a fresh agent takes its first turn, ten times over", context do
        measured =
          measure("An agent starts work by asking what work there is", fn _run ->
            # The production turn prompt, delivered directly rather than through
            # admission. `Work.@prompt` is what an admitted turn carries, so the
            # agent reads exactly what it would read when woken.
            #
            # Admission itself is not used here because it cannot currently
            # deliver a stable premise: the actionable frontier moves between
            # the turn being granted and the agent reading it — measured as
            # `main: ["technical_strategy"]` at admission and
            # `bdd_specs_passing` (coding) at the agent's first call, one turn
            # apart. That is issue c83c5b58 and it is a product defect, not
            # something this criterion should absorb. This measures conduct on
            # the prompt; 3540 covers being woken.
            observe(context, [role: "coding", request_turn: false, say: turn_prompt()], fn agent ->
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
