defmodule CodeMySpecSpex.Story1051.Criterion3449Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3449 — A stopped agent leaves no MCP session behind, so the next one
  to start under its name is not refused.

  Rule: Stopping an agent leaves nothing behind that breaks the next one.

  The named failure. `Agents.restart_agent/2`'s own comment records it:

      {:shutdown, {:failed_to_start_child, Anubis.Client, {:already_started, …}}}

  the new process lost, and the row stuck at `:starting` with `os_pid: nil`
  indefinitely while `restart_agent/2` answered `{:ok, agent}`. Nine minutes
  later nothing had retried.

  The leftover is the MCP client, which registers under a name derived from the
  agent, so the successor collides with a session its predecessor never gave
  up. `Engine.terminate/2` disconnecting on the way down is what closes it —
  and a `terminate/2` that runs is easy to lose without noticing, because
  nothing observes it except the next start.

  Driven as two starts with a stop between them rather than as a restart, so
  what is asserted is the leftover itself. A restart exercises the same
  collision and also the retry around it, which can mask the thing under test.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Stopping an agent leaves nothing behind that breaks the next one" do
    scenario "A stopped agent leaves no MCP session behind" do
      given_ "an agent that has been stopped", context do
        context = given_a_staffed_checkout(context, "spex_3449")
        first = start_agent(context)

        Fixtures.authored_story(context.scope, "a story the agent's tools can find")

        assert {:ok, _} = tool_call(first),
               "the premise is an agent that had a working session to leave behind"

        stop_agent(context, first)

        refute running?(first), "the premise is a stopped agent, and this one is running"

        {:ok, Map.put(context, :first, first)}
      end

      when_ "another agent is started in its place", context do
        {:reply, reply, _frame} =
          StartAgent.execute(
            %{role: "coding", working_copy_id: context.copy_id},
            frame(context)
          )

        {:ok,
         context
         |> Map.put(:reply, reply)
         |> Map.put(:text, response_text(reply))
         |> Map.put(:second, agent_id_in(response_text(reply)))}
      end

      then_ "it starts, rather than being refused because the one before it still holds its session",
            context do
        refute context.reply.isError,
               """
               The successor was refused.

               If the reason is an already-started client, that is the recorded
               failure: the predecessor's MCP session outlived it, the new
               process lost the name, and the row sticks at `:starting` with
               nothing retrying.

               #{context.text}
               """

        assert context.second, "starting reported success and named no agent"

        assert running?(context.second),
               """
               Starting answered success and no agent is running.

               That is the worst of the three outcomes: a caller told the agent
               is up, a page that shows it as asked-for, and nothing anywhere
               that will ever change it.
               """

        {:ok, context}
      end

      then_ "and the successor's own tools work", context do
        assert {:ok, body} = tool_call(context.second),
               """
               The successor started and cannot call a tool.

               A session it merely inherited would behave exactly like this —
               it is registered, so starting succeeds, and it is dead, so every
               call through it fails.
               """

        assert body =~ "a story the agent's tools can find",
               "the successor's tools answered something else: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
