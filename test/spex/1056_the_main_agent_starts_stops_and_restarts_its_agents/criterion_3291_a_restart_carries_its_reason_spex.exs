defmodule CodeMySpecSpex.Story1056.Criterion3291Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3291 — A restart carries its reason.

  Rule: a remedy is recorded with the thing it was meant to remedy.

  This is what makes every later criterion on the story possible. 3292 refuses a
  restart already tried for the same reason, 3302 marks a reason resolved, and
  3308 raises a fault that outlived one — all three need to know *why* each
  restart happened, and a bare count of restarts cannot tell them apart. Three
  restarts for three different faults is a busy morning; three for the same one
  is a loop.

  The reason is also the only thing that makes "did it work" answerable. An
  agent restarted because its tools stopped resolving is fixed when its tools
  resolve — not when it is running, which it was before. Without the reason the
  question degrades to "is it up", which was true of every agent in the outage
  this story came from.

  ## Read back through the transcript, not a field

  The restart is recorded on the agent's own thread, where everything else done
  *to* an agent already goes — `record_orchestrator_action/3` is the existing
  channel for exactly this, and a reader of the transcript should see the restart
  in sequence with the work it interrupted rather than have to go and find it
  somewhere else.
  """

  use CodeMySpecSpex.Case

  # The conversation is a cloud-app surface; the case defaults to the local app.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A restart says what it was for" do
    scenario "the main agent restarts an agent whose tools stopped resolving" do
      given_ "an agent whose machine reports no tools", context do
        reply = join_working_copy(context, "/tmp/spex-3291", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3291"
          )

        CodeMySpecSpex.Fixtures.record_machine_tools(scope, [])

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent restarts it for that reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{
              agent_id: context.agent.id,
              reason: "its tools stopped resolving after the harness reconnected"
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "the reason is recorded with it on the agent's own thread", context do
        {:ok, _live, html} =
          live(
            context.conn,
            CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope, context.agent)
          )

        assert html =~ "its tools stopped resolving after the harness reconnected",
               """
               The restart was recorded with no account of what it was for.

               A bare restart is unjudgeable afterwards. "Did it work" only has
               an answer relative to what it was meant to fix — an agent
               restarted because its tools stopped resolving is fixed when its
               tools resolve, not when it is running, which it was before.
               Without the reason the question degrades to "is it up", and every
               agent in the outage this story came from was up.

               It is also what 3292, 3302 and 3308 all read: three restarts for
               three faults is a busy morning and three for one fault is a loop,
               and a count cannot tell them apart.

               transcript:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
