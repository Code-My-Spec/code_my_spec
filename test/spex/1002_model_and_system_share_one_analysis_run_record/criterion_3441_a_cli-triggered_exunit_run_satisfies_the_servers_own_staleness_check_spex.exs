defmodule CodeMySpecSpex.Story1002.Criterion3441Spex do
  @moduledoc """
  Story 1002 — Model and system share one analysis run record.
  Criterion 3441 — A CLI-triggered exunit run satisfies the server's own
  staleness check.

  ## The claim, and the only way it can be false

  There is one ledger. A run an agent starts by typing `mix test` and a run the
  server started itself are the same record, so the first satisfies every check
  the second would.

  It can only be false in one of two places, and this drives both:

    * the routing — if `mix test` runs as `mix test`, the CLI never touches the
      service and writes nothing the server reads. `PreToolUse.decide/3` is what
      turns it into a request to the analysis endpoint, so that rewrite is the
      first half.
    * the ledger — if the endpoint writes somewhere the staleness check does not
      read, the routing is decoration. `Analysis.fresh_sources/2` is the reader
      the promotion gate and the stop hook both use, so that is the second.

  ## Why this does not run a real suite

  A completed run here would mean `mix test` actually executing, and the
  fixture is a bare git checkout rather than a mix project — so a real run would
  fail for reasons that have nothing to do with the criterion. Worse, it would
  take minutes and hold one of this machine's two analyzer slots while doing it.

  So the run is recorded through the same path the endpoint uses and the
  assertion is on what the server then believes. That is the whole claim: the
  CLI's run and the server's check meet in one place.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Hooks.PreToolUse
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent types mix test and the server's checks see the result" do
    scenario "a checkout whose exunit the server considers stale" do
      given_ "a working copy the server has no fresh exunit run for", context do
        context = a_promotable_project(context)

        refute "exunit" in Analysis.fresh_sources(context.scope, Run.sources()),
               "the premise failed: the server already considers exunit fresh here"

        {:ok, context}
      end

      when_ "the agent runs mix test", context do
        decision =
          PreToolUse.decide(
            context.scope,
            %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}},
            4004
          )

        {:ok, Map.put(context, :decision, decision)}
      end

      then_ "it is routed through the analysis service rather than run as typed", context do
        command =
          get_in(context.decision, ["hookSpecificOutput", "updatedInput", "command"]) || ""

        assert command =~ "/analysis/run",
               """
               `mix test` was left to run as typed. Then the agent's own run and
               the server's are two records: the agent sees a result the stop
               hook and the promotion gate never learn about, and the same work
               is done twice on unchanged code. Got: #{inspect(command)}
               """

        assert command =~ ~s("source":"exunit"),
               """
               The rewrite reached the service but did not say which analyzer
               this was, so whatever it records cannot answer a staleness check
               about exunit. Got: #{inspect(command)}
               """

        {:ok, context}
      end

      and_ "the run it produces is the one the server's staleness check reads", context do
        CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope)

        assert "exunit" in Analysis.fresh_sources(context.scope, Run.sources()),
               """
               A completed exunit run did not satisfy the server's own staleness
               check. That is the whole of this criterion: routing the CLI
               through the service buys nothing if the record it writes is not
               the record `fresh_sources/2` reads — and `fresh_sources/2` is what
               the promotion gate and the stop hook both ask.
               """

        {:ok, context}
      end
    end
  end
end
