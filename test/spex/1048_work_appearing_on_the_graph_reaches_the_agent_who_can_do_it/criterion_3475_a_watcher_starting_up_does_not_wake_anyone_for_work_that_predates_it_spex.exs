defmodule CodeMySpecSpex.Story1048.Criterion3475Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3475 — A watcher starting up does not wake anyone for work that
  predates it.

  A watcher's first pass computes the whole graph, so every actionable
  requirement on the project looks new to it. None of it is: it was there before
  the watcher existed, and the agents on that project have already been told
  about it — or have deliberately not been, which the bootstrap would override.

  This is what makes it more than tidiness. The harness restarts routinely —
  every promote restarts it — and a bootstrap that announces would wake every
  agent on every copy each time, for work none of them has just been given. The
  cost scales with how often the machinery restarts rather than with how often
  the project changes.

  ## Why the watcher is stopped in the `given_`

  `setup_active_project` already starts a watcher for every spex, so "nothing
  watching it" has to be arranged rather than assumed. The watcher is stopped
  first, the work is created while nothing is listening, and only then does a
  watcher start — which is the real sequence after a restart, and the only one
  where "work that predates it" means anything.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers

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

  spex "A watcher's first look at a project is not news" do
    scenario "A watcher starting up does not wake anyone for work that predates it" do
      given_ "a coding agent running and idle", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()

        {:ok, Map.put(context, :coding, coding.id)}
      end

      given_ "nothing is watching the project", context do
        :ok = Fixtures.stop_watching(context.scope)

        {:ok, context}
      end

      given_ "work is already available on the agent's copy", context do
        # Built with the watcher stopped, so nothing observes it appearing —
        # which is what "predates the watcher" has to mean. Every source but
        # `spex` leaves exactly `bdd_specs_passing` outstanding for coding; a
        # kickoff-and-ready-story setup leaves coding nothing, and then the
        # refutation below holds against an implementation that announces its
        # whole bootstrap.
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])

        {:ok, context}
      end

      when_ "a watcher starts and computes the graph for the first time", context do
        :ok = Fixtures.watch_graph(context.scope)

        {:ok, context}
      end

      then_ "no agent is woken", context do
        assert Fixtures.actionable_names(context.scope, :coding) != [],
               """
               There is no coding work on the board, so nothing could have been
               announced and this scenario would pass against an implementation
               that announces its whole bootstrap pass.

               The refutation below is only meaningful while there is work for
               the bootstrap to have wrongly announced.
               """

        told = heard(context, context.coding)

        assert told == [],
               """
               A watcher's first pass woke an agent for work that was already
               there before the watcher started.

               Everything is new to a bootstrap, and none of it is. The harness
               restarts routinely — every promote restarts it — so an announcing
               bootstrap wakes every agent on every copy each time, for work
               none of them has just been given.

               #{length(told)} message(s) arrived:
               #{inspect(told, pretty: true, limit: :infinity)}
               """

        {:ok, context}
      end
    end
  end
end
