defmodule CodeMySpecSpex.Story1024.Criterion2896Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2896 — A message that could not be delivered says so.

  Rule: A message I send reaches the agent.

  The other half of reaching: knowing when it did not. An operator who believes
  they redirected an agent, and did not, waits for a change that is never
  coming — and the agent carries on spending on the thing they were trying to
  stop.

  This is not hypothetical. The send box recorded a message and reported
  nothing, which is indistinguishable from delivery at the call site. The same
  shape has now been found twice on the agent wire: a stop that reported
  success while the process ran, and a start that reported failure while the
  agent ran.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An undelivered message does not look delivered" do
    scenario "A message that could not be delivered says so" do
      given_ "an agent whose machine cannot be reached", context do
        copy = CodeMySpec.TempFile.dir("spex_2896")
        File.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        machine_out_of_reach()

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "I send it a message", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        html =
          live
          |> form("form[phx-submit=send_message]", %{"message" => "stop what you are doing"})
          |> render_submit()

        {:ok, context |> Map.put(:html, html) |> Map.put(:conversation, conversation)}
      end

      then_ "I am told it was not delivered", context do
        assert context.html =~ ~r/could not|not delivered|unreachable/i,
               "the send reported nothing, so an operator believes the agent was " <>
                 "told. They wait for a change that is not coming while the agent " <>
                 "keeps doing the thing they were trying to stop. Got: " <>
                 String.slice(context.html, 0, 300)

        {:ok, context}
      end

      then_ "and the message is not shown as though the agent had received it", context do
        {:ok, _reloaded, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{context.conversation.id}"
          )

        refute html =~ "stop what you are doing",
               "the message is in the transcript over a machine that never got it, " <>
                 "so the record itself is now wrong about what the agent knows"

        {:ok, context}
      end
    end
  end
end
