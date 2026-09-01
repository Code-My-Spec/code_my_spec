defmodule CodeMySpecSpex.Story985.Criterion3038Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3038 — A requirement handed over is on the record

  Rule: Stopping the agent, giving it work, and finishing work on its behalf are
  all recorded.

  An agent that suddenly starts on something new has no visible cause. The
  requirement it was given is the cause, and it lives in the orchestrator rather
  than in anything the agent said — so the transcript shows the agent changing
  subject and nothing about why.

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
    scenario "A requirement handed over is on the record" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "an agent that has just finished something", context do
        {:ok, given_a_main_checkout(context, "the main checkout")}
      end

      when_ "the orchestrator gives it the next requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          CodeMySpec.McpServers.Tasks.Tools.StartTask.execute(
            %{requirement_name: "component_design", entity_type: "component"},
            frame
          )

        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "that is an orchestrator action on the conversation", context do
        assert context.transcript =~ "orchestrator-action",
               "a requirement was handed to the agent and the conversation says nothing " <>
                 "about it. The agent picking up new work is the visible half; what gave " <>
                 "it that work is the half a reader needs."

        {:ok, context}
      end

      then_ "and the agent starting on something new has a visible cause", context do
        refute context.transcript == "",
               "there is no transcript to read at all, so the criterion cannot be judged."

        assert context.transcript =~ ~r/data-test="orchestrator-action"/,
               "without it, somebody watching sees a change of subject and has to guess."

        {:ok, context}
      end
    end
  end
end
