defmodule CodeMySpecSpex.Story1023.Criterion2878Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2878 — A working agent is never reaped for being quiet.

  Rule: An agent whose process outlived its lane is found and ended.

  The inverse of the reaper, and the more expensive half to get wrong. An agent
  thinking for several minutes says nothing, and a reaper keyed on silence would
  kill it mid-thought — losing whatever it was doing and charging for the whole
  run up to that point.

  This is the exact substitution story 892 was reworked to remove one level up:
  a working copy's fate keyed on a liveness signal that only ever runs down,
  which read two mid-session harnesses as 2:21 and 2:25 idle against a two hour
  window. It would be very easy to reintroduce here, because a quiet agent and
  an orphan look identical from anywhere except Presence.

  A lane is joined for exactly as long as its process lives. So the reaper reads
  the lane, never the chatter — and an agent that says nothing but is still
  there is still in the report.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecWeb.HarnessChannel
  alias CodeMySpecWeb.UserSocket
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp report(socket, agents) do
    ref = Phoenix.ChannelTest.push(socket, "agents_running", %{"agents" => agents})

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, payload: payload} -> payload
    after
      2_000 -> flunk("the harness channel never acknowledged agents_running")
    end
  end

  spex "Silence is not absence" do
    scenario "A working agent is never reaped for being quiet" do
      given_ "an agent thinking for several minutes without saying anything", context do
        process = start_process()
        agent = Fixtures.running_agent(context.scope, process, working_copy: "/tmp/quiet-copy")

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_spex_2878", %{scope: context.scope})
          |> subscribe_and_join(HarnessChannel, "harness:#{context.scope.active_account_id}", %{})

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:process, process)
         |> Map.put(:socket, socket)}
      end

      when_ "the machine reports what it is running", context do
        # Its lane is joined — the agent is thinking, not gone — so it is in the
        # set. Saying nothing is not the same as not being there.
        reply =
          report(context.socket, [
            %{
              "working_copy_id" => context.scope.active_working_copy_id,
              "working_copy" => context.agent.working_copy,
              "role" => context.agent.role,
              "provider" => context.agent.provider,
              "os_pid" => context.process.os_pid
            }
          ])

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is still running afterwards", context do
        assert in_group(context.process.os_pid) != [],
               "an agent that was merely quiet had its process ended. It was " <>
                 "mid-thought, everything it was doing is lost, and the whole run " <>
                 "up to that point was paid for."

        {:ok, context}
      end

      then_ "and nothing treated its silence as evidence it was orphaned", context do
        assert Enum.any?(
                 context.reply["running"],
                 &(&1["working_copy"] == context.agent.working_copy)
               ),
               "the server stopped claiming the agent runs while its lane was " <>
                 "still joined. Got: #{inspect(context.reply)}"

        {:ok, agent} = Fixtures.fetch_agent(context.scope, context.agent.id)

        assert agent.status == :running
        assert agent.os_pid == context.process.os_pid

        {:ok, context}
      end
    end
  end
end
