defmodule CodeMySpecSpex.Story1023.Criterion2875Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2875 — A lane leaving is not a process exiting.

  Rule: A stop is not reported done until something confirms the process is
  gone.

  The reconcile used to write `status: :stopped, os_pid: nil` for anything
  missing from a harness report. That is the third shipped instance of this
  defect on the project, and it is on the hot path: the lane going away is real
  evidence that the *lane* died, and it was being read as evidence that the
  process did.

  When the machine cannot be reached to check, the honest answer is to keep
  saying the agent is running. An agent that looks running for another cycle is
  a far better failure than one that looks stopped and is not — the second kind
  is invisible and keeps spending.
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

  spex "The channel is not the evidence" do
    scenario "A lane leaving is not a process exiting" do
      given_ "an agent whose lane has left the harness channel while its process is still alive",
             context do
        process = start_process()
        agent = Fixtures.running_agent(context.scope, process)

        # The machine cannot be reached to check, which is the case that forces
        # the question: with no answer available, is absence enough?
        machine_out_of_reach()

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_spex_2875", %{scope: context.scope})
          |> subscribe_and_join(HarnessChannel, "harness:#{context.scope.active_account_id}", %{})

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:process, process)
         |> Map.put(:socket, socket)}
      end

      when_ "the page reports what is running", context do
        {:ok, Map.put(context, :reply, report(context.socket, []))}
      end

      then_ "that agent is not described as stopped on the strength of the lane going",
            context do
        assert in_group(context.process.os_pid) != [],
               "the premise failed: the process died on its own, so this cannot " <>
                 "distinguish a checked stop from an assumed one"

        {:ok, agent} = Fixtures.fetch_agent(context.scope, context.agent.id)

        refute agent.status == :stopped,
               "the lane went away, nothing could check the process, and the agent " <>
                 "was recorded stopped anyway. It is still running and still " <>
                 "spending, and now nothing is looking for it."

        {:ok, Map.put(context, :after_report, agent)}
      end

      then_ "and the evidence named is the process, not the channel", context do
        assert context.after_report.os_pid == context.process.os_pid,
               "the group id was cleared while the process was still alive, which " <>
                 "is what makes a survivor permanently unreachable — the handle " <>
                 "that could have ended it is gone"

        {:ok, context}
      end
    end
  end
end
