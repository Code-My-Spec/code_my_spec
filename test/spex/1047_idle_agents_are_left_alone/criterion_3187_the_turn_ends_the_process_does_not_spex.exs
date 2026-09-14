defmodule CodeMySpecSpex.Story1047.Criterion3187Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3187 — The turn ends, the process does not.

  The correction this story needs so it cannot be implemented by stopping
  agents. "Leave it alone" and "shut it down" satisfy every silence criterion
  here identically, and only one of them can be woken again when work appears.

  An agent that is stopped costs nothing and is also gone: 3178's doorbell has
  nobody to ring. The state being asked for is a live, idle process — cheap
  because `Alloy.Agent.Server` reaches a provider only when something chats to
  it, so an idle agent spends nothing while remaining something a nudge can
  reach.

  Three Thens, in the order they fail. The stop is allowed; the process
  survives it; and nothing arrives afterwards to undo the point.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.IdleAgentHelpers

  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An idle agent is left running, not shut down" do
    scenario "The turn ends, the process does not" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent really running on a checkout with no coding work", context do
        context = given_a_staffed_checkout(context, "spex_3187")

        # Whoever was already up, so the one this scenario starts can be told
        # apart from them.
        #
        # `Machine.running/0` is `CmsHarness.Agents.running/0` — every agent
        # alive in the harness supervisor on this machine, not this scenario's.
        # Run alone it answers with exactly the agent just started and
        # `[agent_id] =` reads as if it were scoped; run in the suite the
        # analyzer runs, it answered with nineteen and the match blew up. Green
        # in isolation, red in every sweep, which is the shape that makes a
        # story look finished and keeps refusing to flip.
        already_running = Machine.running()

        {:reply, reply, _frame} =
          StartAgent.execute(
            %{role: "coding", working_copy_id: context.copy_id},
            frame(context)
          )

        refute reply.isError,
               "the premise is an agent that is really running, and none started"

        [agent_id] = Machine.running() -- already_running
        context = context |> start_session() |> put_to_work()

        {:ok,
         context
         |> Map.put(:coding, agent_id)
         |> Map.put(:before, heard_count(context, agent_id))}
      end

      when_ "the stop decision is made", context do
        # Dispatched explicitly. This criterion needs a really-running agent,
        # which comes from a checkout joined through the cloud endpoint — and
        # with `@endpoint` pointed there, `~p"/api/hooks/stop"` resolves
        # against a router the hook is not on and 404s.
        response =
          use_cmd_cassette "clean", record: :none do
            context.conn
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(
              CodeMySpecLocalWeb.Endpoint,
              :post,
              "/api/hooks/stop",
              %{
                "session_id" => context.session_id,
                "test_output_files" => clean_analysis()
              }
            )
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent is allowed to end its turn", context do
        refute inspect(context.response) =~ ~r/"decision"\s*=>\s*"block"/,
               """
               The stop was blocked for an agent with nothing to do, so it is
               held open on a turn it has no work for.

               #{inspect(context.response)}
               """

        {:ok, context}
      end

      then_ "and the agent process stays running and idle", context do
        assert running?(context.coding),
               """
               The agent's process is gone.

               "Leave it alone" and "shut it down" satisfy every silence
               criterion on this story identically, and only one of them can be
               woken when work appears — a stopped agent has nobody for 3178's
               doorbell to ring.
               """

        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.coding),
               "the agent survived the stop and is not idle, so it is still spending"

        {:ok, context}
      end

      then_ "and it is sent nothing until work appears", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          "an idle agent that was correctly left running was then spoken to anyway"
        )

        {:ok, context}
      end
    end
  end
end
