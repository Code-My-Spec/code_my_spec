defmodule CodeMySpecSpex.Story1023.Criterion2891Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2891 — An agent I stopped is not resurrected by a restart.

  Rule: Running and stopped are states we set, and the machine is brought to
  match them.

  This hazard did not exist until story 956 gained its resume rule an hour
  before this was written. Bringing agents back after a harness restart is
  obviously right for an agent that was working; run off the wrong question it
  is obviously wrong for one somebody deliberately ended.

  The wrong question is "was this alive before?". Reconciliation that asked that
  would restart exactly the agents a person had just stopped, and they would
  come back consuming, on a machine the person believed they had quieted.

  The right question is what the record *intends*, which is what makes `running`
  a command rather than an observation. A stopped agent is not in the answer at
  all — not suppressed, not filtered, simply not part of what the machine is
  being asked to hold.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stop survives the harness that was serving it" do
    scenario "An agent I stopped is not resurrected by a restart" do
      given_ "two agents on a working copy, one of which I stop", context do
        copy = CodeMySpec.TempFile.dir("spex_2891")
        File.mkdir_p!(copy)

        keep = Fixtures.running_agent(context.scope, role: "coding", working_copy: copy)
        done = Fixtures.running_agent(context.scope, role: "qa", working_copy: copy)

        start_agent(keep.id, working_copy: copy)
        start_agent(done.id, working_copy: copy)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, _reply, _frame} = StopAgent.execute(%{"agent_id" => done.id}, frame)

        refute running?(done.id),
               "the premise is an agent that was actually stopped; without that " <>
                 "this cannot tell a resurrection from an agent that never stopped"

        {:ok, context |> Map.put(:keep, keep) |> Map.put(:done, done) |> Map.put(:copy, copy)}
      end

      when_ "the harness comes back and asks what it should be running", context do
        # The real question the harness asks on join, answered by the real
        # handler. What comes back is what the machine will be told to hold.
        {:ok, Map.put(context, :to_restore, Fixtures.agents_to_restore(context.scope))}
      end

      then_ "the agent I stopped is not in what it is told to run", context do
        ids = Enum.map(context.to_restore, & &1["agent_id"])

        refute context.done.id in ids,
               "an agent somebody stopped is in the set the machine is about to " <>
                 "start. It comes back consuming, on a machine they believed they " <>
                 "had quieted, and nothing they did is what put it there."

        {:ok, Map.put(context, :ids, ids)}
      end

      then_ "and the one still working is", context do
        assert context.keep.id in ids_of(context),
               "the agent that was never stopped was dropped too, which is the " <>
                 "opposite failure and just as much a wrong answer: a restart is " <>
                 "not a reason to abandon work in progress"

        {:ok, context}
      end
    end
  end

  defp ids_of(context), do: context.ids
end
