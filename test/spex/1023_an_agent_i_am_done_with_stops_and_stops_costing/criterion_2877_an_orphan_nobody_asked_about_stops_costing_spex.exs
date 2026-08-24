defmodule CodeMySpecSpex.Story1023.Criterion2877Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2877 — An orphan nobody asked about stops costing.

  Rule: An agent whose process outlived its lane is found and ended.

  Nothing simulates a death here. The harness reports the set of agents it is
  running — a projection of Presence on the lane topics, where a lane is joined
  for exactly as long as it is alive — so an agent whose lane died is simply
  missing from the next report.

  What that absence proves is that the *lane* died. The process may well be
  fine, and if it is, it is still calling a model with nothing watching it. So
  the machine is asked to end the group, and the row is recorded stopped on its
  answer rather than on the absence.
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

  spex "An orphan is ended rather than forgotten" do
    scenario "An orphan nobody asked about stops costing" do
      given_ "an agent process still running on a machine, whose lane died and never came back",
             context do
        process = start_process()
        agent = Fixtures.running_agent(context.scope, process)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_spex_2877", %{scope: context.scope})
          |> subscribe_and_join(HarnessChannel, "harness:#{context.scope.active_account_id}", %{})

        assert in_group(process.os_pid) != [],
               "the premise is a live process whose lane is about to go"

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:process, process)
         |> Map.put(:socket, socket)}
      end

      when_ "the machine next reports what it is running", context do
        # The lane is gone, so it is simply not in the set.
        {:ok, Map.put(context, :reply, report(context.socket, []))}
      end

      then_ "that process is named as one nothing is holding", context do
        assert context.reply["running"] == [],
               "the server still claims the agent is running. Got: " <>
                 inspect(context.reply)

        {:ok, context}
      end

      then_ "and it is ended without me having noticed it", context do
        assert in_group(context.process.os_pid) == [],
               "the lane went away, the row was marked stopped, and the process " <>
                 "is still running. That is the orphan: it keeps calling a model " <>
                 "with nothing watching, and clearing the group id on the way " <>
                 "through is what makes it unreachable afterwards."

        {:ok, context}
      end
    end
  end
end
