defmodule CodeMySpecSpex.Story1023.Criterion2890Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2890 — An agent still working comes back to finish.

  Rule: Running and stopped are states we set, and the machine is brought to
  match them.

  The other half of 2891, and the reason that one is not simply "never restart
  anything". An agent dies with its harness — that is what a supervised process
  is, and `just refresh-harness` runs several times a day — so a restart that
  abandoned every agent mid-story would make the harness unrestartable in
  practice, which is how the previous design ended up with detached OS
  processes, process groups and boot ids.

  What makes coming back cheap here is that the transcript is the state.
  Resurrecting an OS process meant a group id, the boot it belonged to, and a
  reaper for when that went wrong. Restoring a supervised one is starting a
  process with the history it had.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A restart is not a reason to abandon work in progress" do
    scenario "An agent still working comes back to finish" do
      given_ "an agent part-way through a story on a working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2890")
        RealDisk.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "its harness goes down and comes back", context do
        # Going down is the agent going with it: a supervised process does not
        # outlive its supervisor, which is the whole trade the placement
        # decision made.
        :ok = stop_agent_process(context.agent.id)

        refute running?(context.agent.id),
               "the premise is an agent that went down with its harness. Still " <>
                 "running, this asserts nothing about coming back."

        {:ok, Map.put(context, :to_restore, Fixtures.agents_to_restore(context.scope))}
      end

      then_ "it is in what the harness is told to run", context do
        ids = Enum.map(context.to_restore, & &1["agent_id"])

        assert context.agent.id in ids,
               "an agent that was working when its harness restarted was not " <>
                 "brought back. Whatever it was part-way through is abandoned, and " <>
                 "a harness that costs you every agent is one nobody can afford to " <>
                 "restart — which is how the last design ended up detaching " <>
                 "processes from it."

        {:ok, context}
      end

      then_ "and starting it again puts it back on its own checkout", context do
        entry = Enum.find(context.to_restore, &(&1["agent_id"] == context.agent.id))

        assert entry["working_copy"] == context.copy,
               "it would come back on the wrong checkout, which is worse than not " <>
                 "coming back: it resumes a story against a tree that is not the " <>
                 "one it was working in"

        {:ok, context}
      end
    end
  end
end
