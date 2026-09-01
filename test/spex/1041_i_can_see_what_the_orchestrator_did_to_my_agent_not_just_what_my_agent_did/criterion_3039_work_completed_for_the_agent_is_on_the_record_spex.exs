defmodule CodeMySpecSpex.Story985.Criterion3039Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3039 — Work completed for the agent is on the record

  Rule: Stopping the agent, giving it work, and finishing work on its behalf are
  all recorded.

  The other direction, and the one that reads worst without a record: an agent
  moving off a task it was working on looks like it gave up. If something else
  completed that task, the transcript is where that belongs — otherwise the only
  reading available to a person is that the agent abandoned the work.

  ## Scope

  Three kinds, chosen by John in the Three Amigos: the stop decision, a
  requirement fed to the agent, and a task completed on its behalf. A subagent
  being assigned was deliberately left out, and his later note settles that it
  can stay out — work arrives at a role-shaped agent by message, and "giving it
  work" already covers that.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "Stopping the agent, giving it work, and finishing work on its behalf are all recorded" do
    scenario "Work completed for the agent is on the record" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      # This one produces `task_id`, which is what evaluate_task acts on — the
      # spec-file given produces a session and no task handle, so a scenario
      # about finishing a task had nothing to finish.
      given_ :bdd_task_started

      given_ "an agent working on a task", context do
        context = given_a_main_checkout(context, "the main checkout")

        # Opening the conversation is what brings the project's agent into
        # being — `given_a_main_checkout/2` designates the checkout and stops
        # there. Without this the orchestrator acts while `main_agent/1` is
        # still nil, the recorder correctly does nothing, and the `then_` reads
        # as the feature being absent when the premise never held.
        {:ok, Map.put(context, :conversation_path, main_conversation_path(context))}
      end

      when_ "the orchestrator completes that task on its behalf", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          CodeMySpec.McpServers.Tasks.Tools.EvaluateTask.execute(
            %{task_id: context.task_id},
            frame
          )

        {:ok, _live, html} = live(context.conn, context.conversation_path)

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "that is an orchestrator action on the conversation", context do
        assert context.transcript =~ "orchestrator-action",
               "a task was completed for the agent and the conversation is silent about " <>
                 "it."

        {:ok, context}
      end

      then_ "and the agent moving off that work does not look like it gave up", context do
        assert context.transcript =~ ~r/data-test="orchestrator-action"/,
               "an agent that stops working on something, with no record of anything " <>
                 "having finished it, reads as an agent that abandoned it. That is a " <>
                 "conclusion about its judgement drawn from the orchestrator's act."

        {:ok, context}
      end
    end
  end
end
