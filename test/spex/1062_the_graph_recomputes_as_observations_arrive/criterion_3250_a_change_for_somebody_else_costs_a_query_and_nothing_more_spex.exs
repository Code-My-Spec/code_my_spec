defmodule CodeMySpecSpex.Story1062.Criterion3250Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3250 — A change for somebody else costs a query and nothing more.

  Rule: a listener decides whether a change concerns it by querying the graph
  with its own parameters.

  The half of the rule that pays for the other one. Announcing to everybody and
  letting each listener decide is only cheap if deciding "not mine" is cheap —
  otherwise a broadcast design is just a fan-out of interruptions, and the
  agent that had nothing to do is charged a turn every time any other kind of
  work appears anywhere on its project.

  That is the 1047 failure with a new cause. A nudge with nothing behind it
  costs an agent a turn whether it came from a heartbeat or from somebody
  else's issue being filed, and an agent that learns its nudges are empty is
  the thing the whole stop-hook menu exists to prevent.

  Same setup as criterion 3249, opposite assertion: the product observation
  arrives, and the coding agent is left alone. Split from 3249 because this one
  passes on its own in a run where nothing woke at all, so the pair is only
  meaningful when both are green.

  Observed through the coding agent's own transcript — not the index, which
  renders conversation rows and no message text, so a refutation against it
  passes whatever happened.
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

  spex "An agent is not charged a turn for somebody else's work" do
    scenario "a product observation arrives with a coding agent listening" do
      given_ "a product agent and a coding agent, both idle and in the loop",
             context do
        reply = join_working_copy(context, "/tmp/spex-3250", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        product =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "product",
            working_copy: "/tmp/spex-3250"
          )

        coding =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3250"
          )

        # In the loop, or neither is wakeable and this refutation holds for a
        # reason that has nothing to do with routing. Criterion 3249 asserts the
        # positive against the same setup, which is what keeps that from passing
        # unnoticed.
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
            description: "filed with a coding agent listening",
            severity: :medium
          })

        :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the agent it was not for was left alone", context do
        {:ok, live, html} =
          live(
            context.conn,
            CodeMySpecSpex.Fixtures.agent_conversation_path(context.scope, context.coding)
          )

        refute html =~ @wake_text,
               """
               An agent was woken by work of a kind it does not do.

               Announcing to everybody is only cheap if deciding "not mine" is
               cheap. Waking on it instead charges every agent on the project a
               turn every time any kind of work appears anywhere on it — the
               nudge-with-nothing-behind-it of story 1047, arriving from
               somebody else's issue rather than from a heartbeat.
               """

        refute render(live) =~ @wake_text

        {:ok, context}
      end
    end
  end
end
