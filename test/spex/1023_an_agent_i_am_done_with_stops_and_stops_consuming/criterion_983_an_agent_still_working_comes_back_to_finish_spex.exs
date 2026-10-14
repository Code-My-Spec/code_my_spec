defmodule CodeMySpecSpex.Story1023.Criterion983Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 983 — An agent still working comes back to finish.

  Rule: An agent whose process goes without anyone deciding to stop it is
  running again after the harness restarts, with the conversation it had.

  The companion to criterion 984 from the other side of the same
  reconciliation: bringing a mid-story agent back is obviously right, and the
  two sit on either side of the one question reconciliation actually asks —
  not "was this alive before" but "does the record still intend it running".
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work in progress survives a restart it did not ask for", criterion: 983 do
    scenario "An agent still working comes back to finish" do
      given_ "an agent part-way through a story in its working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2890_resume")
        RealDisk.mkdir_p!(copy)

        {:ok, _integration} = Fixtures.connect_provider(context.scope, :zai)
        agent = Fixtures.running_agent(context.scope, role: "coding", working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2890", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        agent_id = start_agent_with_provider(agent.id, working_copy: copy, report_to: socket)

        begin_turn(agent_id)
        finish_turn(agent_id)

        assert agent_knows?(agent_id, "work on something"),
               "the premise is an agent partway through something, with that in its " <>
                 "conversation; without it this cannot tell a resume carrying its history " <>
                 "from one starting fresh"

        # What a harness restart does to a process it never decided to stop:
        # the process goes, the record's intent does not.
        stop_agent_process(agent_id)

        refute running?(agent_id),
               "the premise is a process that actually went away; without that a " <>
                 "restart proves nothing about bringing it back"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:agent_id, agent_id)}
      end

      when_ "its harness restarts", context do
        requests = Fixtures.agents_to_restore(context.scope)
        request = Enum.find(requests, &(&1["agent_id"] == context.agent_id))

        assert request,
               "the server did not tell the restarting harness to bring this agent back " <>
                 "at all, so there is nothing for the rest of this scenario to launch"

        assert {:ok, _} = Fixtures.launch_agent(request),
               "the harness could not relaunch the agent from what the server sent, so " <>
                 "what follows is about a launch that never happened rather than a resume"

        {:ok, context}
      end

      then_ "the agent is running again with its conversation", context do
        assert running?(context.agent_id),
               "an agent that was working when the harness went down is not running " <>
                 "again after it comes back"

        {:ok, context}
      end

      then_ "and it carries on from where it was", context do
        assert agent_knows?(context.agent_id, "work on something"),
               "the agent came back with no memory of what it was doing — it is " <>
                 "running again, but not carrying on from where it was"

        {:ok, context}
      end
    end
  end
end
