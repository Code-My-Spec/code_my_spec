defmodule CodeMySpecSpex.Story1023.Criterion2883Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2883 — A group id from before the last boot names nobody.

  Rule: An agent runs in its own process group, and that group is what gets
  signalled.

  Process group ids are reused. One recorded before a reboot can name an
  unrelated process afterwards, and signalling it is the worst failure available
  here: it kills a stranger's process, on somebody's machine, and nothing would
  ever trace it back.

  So the boot the number belongs to is recorded beside it and liveness is "same
  boot **and** the group exists". A handle from a previous boot is not ours, and
  the only safe thing to do with it is nothing.

  Both answers are wrong for such a handle, which is why it gives neither:
  signalling may reach a stranger, and reporting a stop claims one that did not
  happen over a process that may still be spending.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A recycled group id is not ours to signal" do
    scenario "A group id from before the last boot names nobody" do
      given_ "an agent whose recorded group id survives a reboot, with an unrelated process now holding that number",
             context do
        # The unrelated process. Its group is live and has nothing to do with us
        # — which is exactly what a recycled number looks like.
        stranger = start_process()

        agent =
          Fixtures.running_agent(context.scope, %{
            os_pid: stranger.os_pid,
            os_boot_id: "a-boot-that-has-since-ended"
          })

        assert in_group(stranger.os_pid) != [],
               "the premise needs a live process holding the recycled number"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:stranger, stranger)}
      end

      when_ "the machine reaps what nothing is holding", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it signals nothing", context do
        assert in_group(context.stranger.os_pid) != [],
               "the stop signalled a group recorded before a reboot. That number " <>
                 "now belongs to something else, on somebody's machine, and killing " <>
                 "it is a failure nobody would ever trace back here."

        {:ok, context}
      end

      then_ "and the unrelated process is untouched", context do
        assert length(in_group(context.stranger.os_pid)) >= 1

        {:ok, context}
      end
    end
  end
end
