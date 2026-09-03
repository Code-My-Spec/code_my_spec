defmodule CodeMySpecSpex.Story1043.Criterion3056Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3056 — Waiting is the orchestrator's job, not the agent's.

  Rule: The agent is never told to wait for the analyzers.

  The rule that says this is not a port of the hook.

  `Hooks.Stop` has a `pending_analysis?` branch. When the analyzers have not
  finished it hands the agent `wait_directive/1` — literally
  `curl -sS -X POST localhost:4004/api/harnesses/<id>/analysis/wait ... then stop
  again`. That exists because a hook must answer *now* with an answer that does
  not exist yet, and it is the mechanical cause of the one-turn-late problem
  story 1042 was written about.

  An internal agent is a live process. It stops, the analyzers run, and the
  decision is sent when it exists. So there is no pending branch here and there
  must not be one: the moment somebody ports the hook's shape wholesale, the
  agent starts being told to poll an endpoint and end a turn a second time to
  find out what the first one broke.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent is never told to wait for the analyzers" do
    scenario "Waiting is the orchestrator's job, not the agent's" do
      given_ "an agent running under Alloy whose analyzers have not finished", context do
        # Story 988's criterion 8201's recipe, plus the state this criterion is
        # actually about.
        #
        # Two things have to be true at once, and neither is free. The finding
        # must *block*, or nothing is delivered and every refutation below
        # passes against an empty list — which is what this scenario did until
        # QA found the directive live. And the source must be **stale**, because
        # the wait remedy only appears in the footer a stale source produces; a
        # fresh one renders no remedy at all and the refutes go vacuous a second
        # way.
        #
        # `stale_analysis_run/2` is the difference between stale and never-ran:
        # a completed run whose fingerprint has moved on still blocks and still
        # explains itself, where a source with no run at all is simply not
        # enforced.
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        Fixtures.record_problem(context.scope, "credo", %{
          file_path: @impl_path,
          message: "Modules should have a @moduledoc tag"
        })

        Fixtures.stale_analysis_run(context.scope, "credo")

        assert {:error, reason} = Fixtures.validate_stop(context.scope),
               "the finding must block, or the refutations below assert against nothing"

        assert reason =~ "stale",
               """
               The source is not stale, so the response carries no footer about
               reruns at all and the refutations below would pass whatever the
               code did. Got:

               #{reason}
               """

        # What this scenario can and cannot reach.
        #
        # The `curl analysis/wait` remedy lives behind `wait_or_report/4`'s
        # "a rerun is in flight" branch, and `Analysis.in_flight/1` reads the
        # analysis Registry rather than the ledger — with no ProjectServer for
        # this project the state is `:untracked`, so no ledger row can put a
        # source in flight from here. The remedy's two renderings are asserted
        # directly against `ProblemRenderer` in
        # `test/code_my_spec/problems/problem_renderer_wait_remedy_test.exs`,
        # which is a pure function and the honest place for it.
        #
        # What is left here is still worth having, and is the half that was
        # missing: a decision really is delivered, and none of the hook's
        # waiting vocabulary appears anywhere in it.

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "its turn ends and it is next addressed", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        told = Fixtures.orchestrator_actions(context.scope, context.agent_id)

        assert told != [], """
        The agent was told nothing at all, so the refutations below prove
        nothing about what it was told. A blocking finding was established in
        the premise precisely so there would be a message to inspect.
        """

        {:ok, Map.put(context, :told, told)}
      end

      then_ "it is not asked to wait for them", context do
        said = Enum.join(context.told, "\n")

        refute said =~ "analysis/wait", """
        The agent was handed the hook's wait directive. That endpoint exists so
        an external agent can block on analyzers a hook could not wait for; this
        one is a process the orchestrator can simply tell, and porting the
        instruction reintroduces the delay it was written to work around.

        Got: #{inspect(context.told)}
        """

        refute said =~ "curl", "the agent was handed a shell command to run"

        {:ok, context}
      end

      then_ "and it is not asked to end a turn again to find out", context do
        said = Enum.join(context.told, "\n")

        refute said =~ "stop again", """
        The agent was told to end another turn to learn what the last one broke.
        That is the one-turn-late problem, arriving on the path that was
        supposed to be free of it.
        """

        {:ok, context}
      end
    end
  end
end
