defmodule CodeMySpecSpex.Story1018.Criterion979Spex do
  @moduledoc """
  Story 1018, criterion 979: an agent writes into the checkout on its machine.

  The model endpoint is local and instructs a real harness agent to call its
  real write tool. This checkout has no server file writer attached: a write
  that depends on asking the server cannot put the file here.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers,
    only: [start_agent_with_provider: 2, begin_turn: 1]

  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent edits the checkout it was started in", criterion: 979 do
    scenario "a local agent writes a file without a server file writer" do
      given_ "a working copy on this machine", context do
        copy = CodeMySpec.TempFile.dir("spex_979")
        RealDisk.mkdir_p!(copy)
        agent = Fixtures.running_agent(context.scope, working_copy: copy)

        {:ok, Map.merge(context, %{copy: copy, agent: agent})}
      end

      when_ "an agent starts on that copy and is asked to write a file", context do
        agent_id = start_agent_with_provider(context.agent.id, working_copy: context.copy)
        path = Path.join(context.copy, "from-agent.txt")
        begin_turn(agent_id)

        :ok =
          HeldProvider.release_with_tool_call(
            "write",
            %{"file_path" => path, "content" => "written by the local agent\n"},
            then: :hold
          )

        # The follow-up model request arrives only after the real write tool
        # has returned. Leave that request held until test teardown.
        :ok = HeldProvider.await_request()
        {:ok, Map.put(context, :written_path, path)}
      end

      then_ "the file exists in that checkout on that machine", context do
        assert RealDisk.read!(context.written_path) == "written by the local agent\n"
        {:ok, context}
      end

      then_ "the agent did not ask the server to write it", context do
        assert context.copy != context.scope.cwd
        refute RealDisk.exists?(Path.join(context.scope.cwd, "from-agent.txt"))
        {:ok, context}
      end
    end
  end
end
