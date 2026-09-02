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

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent is never told to wait for the analyzers" do
    scenario "Waiting is the orchestrator's job, not the agent's" do
      given_ "an agent running under Alloy whose analyzers have not finished", context do
        Fixtures.deliver_manifest(context.scope)
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        Fixtures.record_problem(context.scope, "credo", %{
          file_path: "lib/example_context.ex",
          message: "Modules should have a @moduledoc tag"
        })

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "its turn ends and it is next addressed", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok,
         Map.put(context, :told, Fixtures.orchestrator_actions(context.scope, context.agent_id))}
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
