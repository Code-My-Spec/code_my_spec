defmodule CodeMySpecSpex.Story1043.Criterion3058Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3058 — Stopping on purpose is not a delivery failure.

  Rule: An agent that has halted is not owed a decision, and not reported as a
  failure.

  Delivery to a process introduces a state a hook never had: the recipient can
  be gone. `Engine.send_message/4` answers `{:error, :not_running}` when there
  is no pid, and that is the correct answer rather than a failed delivery — an
  agent halted on purpose is not owed the news.

  What this forbids is the noisy reading of that state. An error record, a
  warning on every landing, or a retry against a process nobody intends to bring
  back all turn "nobody to tell" into "could not tell", and a log that cries
  about a normal state is one people learn to skip.
  """

  use CodeMySpecSpex.Case

  import ExUnit.CaptureLog

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent that has halted is not owed a decision, and not reported as a failure" do
    scenario "Stopping on purpose is not a delivery failure" do
      given_ "an agent running under Alloy that has been halted", context do
        Fixtures.deliver_manifest(context.scope)
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        Fixtures.record_problem(context.scope, "credo", %{
          file_path: "lib/example_context.ex",
          message: "Modules should have a @moduledoc tag"
        })

        agent_id = running_agent(context)
        :ok = Fixtures.halt_agent(agent_id)

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "the analyzers for its working copy complete with problems", context do
        logged =
          capture_log(fn ->
            :ok = Fixtures.end_turn(context.scope, context.agent_id)
          end)

        {:ok, Map.put(context, :logged, logged)}
      end

      then_ "nothing is recorded as having gone wrong", context do
        refute context.logged =~ "[error]", """
        Deciding for a halted agent was recorded as an error. There is nobody to
        tell, which is a state and not a fault — and an error on a normal state
        teaches whoever reads the log to skip a line that will eventually
        matter.

        Got: #{inspect(context.logged)}
        """

        {:ok, context}
      end

      then_ "and the agent is still stopped", context do
        assert {:error, :not_running} = Fixtures.agent_status(context.agent_id), """
        The halted agent is answering again, so something restarted it to
        deliver a decision. An agent that stopped on purpose stays stopped.
        """

        {:ok, context}
      end
    end
  end
end
