defmodule CodeMySpecSpex.Story1062.Criterion3249Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3249 — An agent's own process decides whether the change was for it.

  Rule: a listener decides whether a change concerns it by querying the graph
  with its own parameters.

  The announcement carries a project id and nothing else (criterion 3355), so
  by itself it cannot say who a change was for. That is deliberate: the graph
  would have to know every listener's parameters to route, and every new kind
  of listener would then be a change to the thing announcing.

  Two agents of different kinds are on this project, and one observation
  arrives. Both hear the same announcement; only one of them finds work in it.
  The difference is made entirely by what each asks the graph — the roles'
  requirement names are their parameters.

  The other half is criterion 3250: the agent this was not for is not woken.
  Split because a run where neither is woken satisfies 3250 on its own, and
  because the failure that matters most is the one where both are.

  Observed through each agent's own transcript. `StopDecision.do_wake/2` finds
  or creates it and sends "Work of your kind is available." plus the menu, so a
  woken agent has that sentence and an un-woken one does not.
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

  spex "Each listener works out for itself whether a change was its own" do
    scenario "a product observation arrives with two kinds of agent listening" do
      given_ "a product agent and a coding agent, both idle and in the loop",
             context do
        reply = join_working_copy(context, "/tmp/spex-3249", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        product =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "product",
            working_copy: "/tmp/spex-3249"
          )

        coding =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3249"
          )

        # Only an agent in the loop is woken at all. Without this both are left
        # alone for a reason that has nothing to do with the criterion, and the
        # assertion below would fail while the refutation in 3250 passed — the
        # pair reading as "routing works" when nothing was routed.
        frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

        {:reply, loop_response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: reply.working_copy_id, working: true},
            frame
          )

        refute loop_response.isError,
               "the agents must be in the loop to be wakeable:\n" <> inspect(loop_response)

        :ok = CodeMySpecSpex.Fixtures.watch_graph(scope)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:product, product)
         |> Map.put(:coding, coding)}
      end

      when_ "an issue is filed, which is work of the product kind", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "something only product triages",
            description: "filed with two kinds of agent listening",
            severity: :medium
          })

        :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the agent whose kind of work it is finds it", context do
        {:ok, _live, html} =
          live(
            context.conn,
            CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope, context.product)
          )

        assert html =~ @wake_text,
               """
               The announcement went out and the agent it was for heard nothing.

               The announcement names a project and no role, so being told
               "something moved" is all any listener gets — working out whether
               it moved for them is their own query's job. If a listener cannot
               do that, the only way to route a change is for the graph to know
               every listener, which is the coupling this rule exists to avoid.
               """

        {:ok, context}
      end
    end
  end
end
