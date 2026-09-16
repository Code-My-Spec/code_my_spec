defmodule CodeMySpecSpex.Story1048.Criterion3474Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3474 — Work still waiting does not wake the agent a second time.

  The wake is for work *appearing*, not for work *existing*. An agent already
  told about a requirement and part-way through it knows; saying so again tells
  it nothing and costs a turn to rediscover.

  ## What answers it, and it is not a dedupe

  `StopDecision.wake/2` already asks the only question that matters: is this
  agent working. An agent with `turn_started_at` set is left alone, so later
  graph changes are dropped rather than queued, and the menu at the end of its
  own turn is where it finds out what is next.

  So a repeat means the agent never started. Chasing this as deduplication —
  keying on the rendered menu, counting repeats, tracking which vantage moved —
  solves at the sender something the receiver already knows.

  ## The shape has to be the production one

  A fixture agent is woken and then just sits there, so every later observation
  finds it idle and correctly wakes it again. Measured in that shape: five
  identical wakes, which is `@stuck_threshold` rather than anything about the
  wake.

  So the scenario is built in the order the product actually runs: the project
  state first, with no agent to wake; then an idle agent with work outstanding;
  then **one** observation, which wakes it once; then the agent begins its turn,
  the way a woken agent does; then a further observation, which must find it
  working and be dropped.

  ## Not the same as 3190

  3190's agent has nothing to do and is sent a change with nothing in it for it.
  This agent does have outstanding work and was already told — the question is
  only whether a later recompute repeats itself.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is told when work appears, not while it remains" do
    scenario "Work still waiting does not wake the agent a second time" do
      given_ "a project with one piece of coding work outstanding", context do
        # Built before any agent exists, so the observations this chain produces
        # have nobody to wake and cannot be mistaken for the one wake below.
        # Every source but `spex` leaves exactly `bdd_specs_passing`.
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        :ok = Fixtures.settle_graph(context.scope)

        outstanding = Fixtures.actionable_names(context.scope, :coding)

        assert outstanding != [],
               """
               The premise is a requirement the agent is woken for and has not
               finished, and there is none — so a silent second recompute below
               would be correct rather than the defect this criterion names.
               """

        {:ok, Map.put(context, :outstanding, outstanding)}
      end

      given_ "a coding agent running and idle on that copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok, Map.put(context, :coding, coding.id)}
      end

      given_ "it has been woken for that requirement and has begun its turn", context do
        elsewhere = join_working_copy(context, "/tmp/spex-3474-first", "another checkout")
        first_scope = %{context.scope | active_working_copy_id: elsewhere.working_copy_id}

        story = Fixtures.released_story(first_scope, "Statements render as PDF")
        Fixtures.record_deploy(first_scope, story.id, "dev")
        :ok = Fixtures.settle_graph(context.scope)

        woken = heard(context, context.coding)

        assert woken != [],
               """
               The agent was never woken, so there is nothing for a second
               observation to repeat and the scenario never set itself up.
               """

        # A woken agent responds. `turn_started_at` is how `wake/2` knows, and
        # recording it through `record_turn_event/3` is the route the harness
        # takes when an agent begins — writing the column directly would set the
        # same field by a path the product never uses.
        #
        # Counted from here rather than from zero: a fixture chain emits several
        # observations and the agent cannot begin a turn between them, so the
        # setup's own wake count is an artefact of not having a live agent. What
        # the criterion asks is whether anything *further* arrives once it is
        # working, and that is the delta across the `when_`.
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coding)

        {:ok, Map.put(context, :told_by_now, length(woken))}
      end

      when_ "another observation arrives and the graph is recomputed", context do
        other = join_working_copy(context, "/tmp/spex-3474-second", "a third checkout")
        other_scope = %{context.scope | active_working_copy_id: other.working_copy_id}

        later = Fixtures.released_story(other_scope, "Invoices reconcile to the ledger")
        Fixtures.record_deploy(other_scope, later.id, "dev")

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      when_ "and that requirement is still the only work available", context do
        still = Fixtures.actionable_names(context.scope, :coding)

        assert still == context.outstanding,
               """
               The observation changed what coding has to do, so this scenario
               is no longer asking its own question — a wake would be the right
               answer to new work rather than a repeat of old work.

               Before: #{inspect(context.outstanding)}
               After:  #{inspect(still)}
               """

        {:ok, context}
      end

      then_ "the agent is not woken again", context do
        told = heard(context, context.coding)
        arrived = Enum.drop(told, context.told_by_now)

        assert arrived == [],
               """
               A wake reached an agent that was already working, for a
               requirement it had been given and not yet finished.

               It tells the agent nothing it is not already holding and costs a
               turn to rediscover — and on a busy project the graph recomputes
               constantly, so this is per observation rather than per change
               that matters.

               #{length(arrived)} message(s) arrived after it began its turn:
               #{inspect(arrived, pretty: true, limit: :infinity)}
               """

        {:ok, context}
      end
    end
  end
end
