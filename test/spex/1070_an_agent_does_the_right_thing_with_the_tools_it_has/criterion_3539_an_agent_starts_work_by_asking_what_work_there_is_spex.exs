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
        {:ok, given_a_harnessed_checkout(context, "eval_3539", root: :project)}
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
            # One run until the premise can regenerate, and the blocker is the
            # spex environment rather than this criterion.
            #
            # These are real turns and they finish the work: run 1's agent
            # claimed `technical_strategy`, read the architecture overview and
            # the workflow, and satisfied it — so at n=10 run 2 arrived to
            # `main: []`. Handing each run its own story does not help, because
            # no story requirement is actionable while the project chain is
            # open, and the chain cannot be closed from here.
            #
            # `impl(:memory)` is `Support.InMemoryEnvironment`, so
            # `Environments.write_file/3` answers `:ok` and puts nothing on
            # disk. The fixture's `.code_my_spec/architecture/decisions.md`
            # exists as a File row and not as a file. A real agent reads real
            # files, so the fixture and the agent are looking at two different
            # filesystems — which is fine for a spex that drives a surface and
            # is exactly wrong for one that drives an agent.
            #
            # Evals need a disk-backed environment rooted at the checkout the
            # agent works in. That is an infrastructure change, not a fixture
            # tweak, and n=10 waits on it.
            observe(context, [role: "main"], fn agent ->
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
