defmodule CodeMySpecSpex.Story1042.Criterion3049Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3049 — A stopped agent is a stopped agent, not a lost message.

  Rule: An agent that has halted is not owed delivery, and not reported as a
  failure.

  Delivery to a process is the whole reason the internal path is better than a
  hook, and it introduces a state a hook never had: the recipient can be gone.
  `CmsHarness.Agents.Engine.send_message/4` resolves a pid and answers
  `{:error, :not_running}` when there is none — which is the correct answer, not
  a delivery failure. An agent halted on purpose is not owed the news.

  What this forbids is the noisy reading of that state: a warning, an error
  record, or a retry against a process nobody intends to bring back. Whoever
  implements the delivery has to distinguish "nobody to tell" from "could not
  tell", and this is where that gets pinned.
  """

  use CodeMySpecSpex.Case

  import ExUnit.CaptureLog

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent that has halted is not owed a decision, and not reported as a failure" do
    scenario "A stopped agent is a stopped agent, not a lost message" do
      given_ "an agent running under Alloy has been halted", context do
        agent_id = running_agent(context)
        :ok = Fixtures.halt_agent(agent_id)

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "an analyzer run for its working copy lands with problems", context do
        logged =
          capture_log(fn ->
            Fixtures.problem_fixture(context.scope, %{
              source: "compiler",
              message: "** (SyntaxError) missing terminator: end",
              file_path: "lib/example_context.ex"
            })
          end)

        {:ok, Map.put(context, :logged, logged)}
      end

      then_ "nothing is delivered", context do
        assert {:error, _reason} = Fixtures.run_script("return 1", agent_context(context)),
               "a halted agent answered a tool call, so it was not halted"

        {:ok, context}
      end

      then_ "and nothing is recorded as having gone wrong", context do
        refute context.logged =~ "[error]", """
        Landing a finding with no agent to tell was recorded as an error. There
        is nobody to tell and that is a state, not a fault — logging it teaches
        whoever reads the log to skip a line that will eventually matter.

        Got: #{inspect(context.logged)}
        """

        {:ok, context}
      end
    end
  end
end
