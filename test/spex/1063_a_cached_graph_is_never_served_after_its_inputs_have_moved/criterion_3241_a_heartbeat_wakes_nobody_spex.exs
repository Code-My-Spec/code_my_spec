defmodule CodeMySpecSpex.Story1063.Criterion3241Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3241 — A heartbeat wakes nobody.

  Rule: a domain event is trusted, and a liveness report is not a domain event.

  3231 says a heartbeat does not move the graph. This says the consequence that
  makes that worth having: nobody is woken by it. A graph that recomputed on
  every liveness report would wake every continuous agent on the project every
  time any checkout reported in, which is the failure story 1047 exists to stop
  — an agent charged a turn for a nudge with nothing behind it.

  Observed through the agent's own conversation. `StopDecision.do_wake/2`
  finds or creates the agent's conversation and sends "Work of your kind is
  available." plus the menu, so a woken agent has that sentence and an
  un-woken one does not.
  """

  use CodeMySpecSpex.Case

  # The agent conversation is a cloud-app surface. The case's default endpoint
  # is the local app, and `live/2` against it answers a 404 that surfaces as a
  # FunctionClauseError inside LiveViewTest rather than as a missing route.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @state %{ahead: 0, behind: 0, dirty: false}
  @wake_text "Work of your kind is available"

  spex "A liveness report does not charge an agent a turn" do
    scenario "the checkout reports in and an idle agent is running" do
      given_ "a coding agent in the loop on a checkout that has already reported",
             context do
        reply = join_working_copy(context, "/tmp/spex-3241", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3241"
          )

        # In the loop, or it would not be woken by anything and the refutation
        # below would hold for the wrong reason.
        frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

        {:reply, loop_response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: reply.working_copy_id, working: true},
            frame
          )

        refute loop_response.isError, inspect(loop_response)

        :ok = CodeMySpecSpex.Fixtures.record_git_state(reply.working_copy_id, @state)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:agent, agent)
         |> Map.put(:working_copy_id, reply.working_copy_id)}
      end

      when_ "the checkout reports in again with nothing about it changed", context do
        :ok = CodeMySpecSpex.Fixtures.record_git_state(context.working_copy_id, @state)
        {:ok, context}
      end

      then_ "no agent was told there is work of its kind available", context do
        # The per-agent conversation. The index renders conversation rows and
        # no message text, so a refutation against it passes whatever happened
        # — which is how this criterion was green for the wrong reason before.
        {:ok, live, html} =
          live(context.conn, CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope))

        refute html =~ @wake_text,
               """
               An agent was woken by a liveness report.

               A checkout saying "I am still here" with nothing about it changed
               is not work appearing. Waking on it charges every continuous
               agent on the project a turn every time any checkout reports in,
               which is exactly the nudge-with-nothing-behind-it that story 1047
               exists to stop.
               """

        refute render(live) =~ @wake_text

        {:ok, context}
      end
    end
  end
end
