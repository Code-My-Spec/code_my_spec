defmodule CodeMySpecSpex.Story1056.Criterion3293Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3293 — A restart that makes things worse is visible as such.

  Rule: the remedy is in the record, in sequence with what it did.

  The story's trap, stated in its own notes: restarting an agent was what
  *caused* one outage. So this story cannot only be about being able to restart
  — it has to be about knowing whether restarting was the right move, and that
  is only answerable if the restart sits in the record at the moment it
  happened.

  The failure is not that the information is missing. It is that the information
  is present and unconnected: an agent that was working, a restart somewhere, an
  agent that is not working. Read apart, the last one is a fault to be fixed and
  the middle one is unrelated housekeeping — and the main agent's next move is
  another restart, which is the loop 3292 is about, entered through a different
  door.

  ## Asserted as ordering, not as a claim

  The transcript has to put the restart between the working and the not-working,
  which is the only thing that makes it legible as the turning point. Nothing
  here asks the view to *say* the restart broke it — that is a conclusion, and
  criterion 3275 on story 1054 is the rule against drawing those. The main agent
  reads the order and decides.
  """

  use CodeMySpecSpex.Case

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

  spex "The restart is where the record says the agent stopped working" do
    scenario "an agent was working before a restart and is not after one" do
      given_ "an agent that was working", context do
        reply = join_working_copy(context, "/tmp/spex-3293", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3293"
          )

        :ok =
          CodeMySpecSpex.Fixtures.agent_said(scope, agent, "the exporter passes its tests now")

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent restarts it and it stops working", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent.id, reason: "tidying up before the next story"},
            frame
          )

        refute response.isError, inspect(response)

        # Afterwards, and only afterwards, it cannot reach anything.
        CodeMySpecSpex.Fixtures.record_machine_tools(context.scope, [])

        {:ok, context}
      end

      then_ "the restart sits between the working and the not working", context do
        {:ok, _live, html} =
          live(
            context.conn,
            CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope, context.agent)
          )

        working = position(html, "the exporter passes its tests now")
        restart = position(html, "tidying up before the next story")

        assert working, "the agent's earlier work is not in its transcript:\n#{html}"

        assert restart,
               """
               The restart is nowhere in the agent's record.

               Then an agent that was working, a restart, and an agent that is
               not working are three facts nobody can put in order — and read
               apart, the last is a fault to fix and the restart is unrelated
               housekeeping. The main agent's next move is another restart,
               which is 3292's loop entered through a different door.

               transcript:
               #{html}
               """

        assert working < restart,
               """
               The restart is recorded before the work it interrupted.

               Order is the whole of this criterion. The restart is only legible
               as the turning point if it sits between the agent working and the
               agent not working; out of sequence it is just another entry.

               work at #{working}, restart at #{restart}
               """

        {:ok, context}
      end
    end
  end

  defp position(html, needle), do: index_of(:binary.match(html, needle))

  defp index_of(:nomatch), do: nil
  defp index_of({at, _length}), do: at
end
