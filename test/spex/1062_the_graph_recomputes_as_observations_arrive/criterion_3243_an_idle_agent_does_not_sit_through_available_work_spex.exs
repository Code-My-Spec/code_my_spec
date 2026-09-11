defmodule CodeMySpecSpex.Story1062.Criterion3243Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3243 — An idle agent does not sit through available work.

  Rule: the graph updates when something is written, not only when something
  reads it.

  The consequence that makes the rule worth having. A graph that recomputes on
  a write and tells nobody is an improvement in principle and invisible in
  practice — the point is the agent that was waiting.

  This is the 2026-09-07 incident stated as an outcome rather than as a
  mechanism: a product agent stopped correctly with an empty queue, said it
  would wait to be woken when a product requirement was unblocked, and sat for
  ninety minutes while four issues were filed and `issues_triaged` became
  actionable again.

  Observed through the agent's own conversation. `StopDecision.do_wake/2`
  creates or finds it and sends "Work of your kind is available." plus the
  menu, so a woken agent has that sentence and an un-woken one does not.
  """

  use CodeMySpecSpex.Case

  # The conversation is a cloud-app surface; the case's default endpoint is the
  # local app, where `live/2` answers 404 from inside LiveViewTest.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @wake_text "Work of your kind is available"

  spex "An agent waiting for work is told when it appears" do
    scenario "an issue is filed while a product agent is idle" do
      given_ "an idle product agent on a watched project", context do
        reply = join_working_copy(context, "/tmp/spex-3243", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "product",
            working_copy: "/tmp/spex-3243"
          )

        # Only an agent in the loop is woken — `project_wakeable?/2` wants
        # `continuous: true`, and an agent that has not been put to work is
        # deliberately left alone. The loop switch is the surface that does it.
        frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

        {:reply, loop_response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: reply.working_copy_id, working: true},
            frame
          )

        refute loop_response.isError,
               "the agent must be in the loop to be wakeable:\n" <> inspect(loop_response)

        :ok = CodeMySpecSpex.Fixtures.watch_graph(scope)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "an issue is filed, making work available for its role", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "something for product to triage",
            description: "filed while the product agent was idle",
            severity: :medium
          })

        :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the agent is told there is work of its kind available", context do
        # The per-agent conversation, not the index. The index renders rows of
        # conversations and no message text, so asserting on it says nothing
        # either way — a refute against it passes whatever happened.
        {:ok, _live, html} =
          live(context.conn, CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope))

        assert html =~ @wake_text,
               """
               An issue was filed, the graph moved, and the agent that triages
               issues heard nothing.

               This is the ninety minutes of 2026-09-07: the agent said it would
               wait to be woken when a product requirement was unblocked, and
               filing an issue is exactly that happening. A graph that
               recomputes on a write and tells nobody is an improvement nobody
               can observe.
               """

        {:ok, context}
      end
    end
  end
end
