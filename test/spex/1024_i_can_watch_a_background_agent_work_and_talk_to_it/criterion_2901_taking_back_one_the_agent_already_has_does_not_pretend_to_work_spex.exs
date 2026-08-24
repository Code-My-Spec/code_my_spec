defmodule CodeMySpecSpex.Story1024.Criterion2901Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2901 — Taking back one the agent already has does not pretend to work.

  Rule: A message waiting to be delivered can be taken back.

  The race that makes withdrawal dangerous. A turn ends while you are reaching
  for the control, the queued message is delivered, and your click lands a
  moment later. If that reports success, the operator's belief and the agent's
  behaviour part company: they think it was withdrawn, the agent is acting on
  it, and everything the agent does next reads as inexplicable.

  Better to be told you were too late. The window is small and it is exactly
  the window in which people click, because they click when the turn is about
  to end.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Too late is not the same as done" do
    scenario "Taking back one the agent already has does not pretend to work" do
      given_ "a message the agent has already picked up", context do
        copy = CodeMySpec.TempFile.dir("spex_2901")
        File.mkdir_p!(copy)

        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)
        Fixtures.agent_begins_turn(context.scope, agent)

        conversation = Fixtures.agent_conversation(context.scope, agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        live
        |> form("form[phx-submit=send_message]", %{"message" => "too late to stop this"})
        |> render_submit()

        # The turn ends and the queued message goes out, which is the race: the
        # operator is reaching for the control while this happens.
        Fixtures.agent_finishes_turn(context.scope, agent)

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:live, live)}
      end

      when_ "I try to take it back", context do
        html = Fixtures.withdraw_pending(context.live)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "I am told it has already been delivered", context do
        assert context.html =~ ~r/already (been )?(delivered|sent)|too late/i,
               "withdrawing a message the agent already has reported success. The " <>
                 "operator believes it was taken back, the agent is acting on it, and " <>
                 "everything it does next reads as inexplicable. Got: " <>
                 String.slice(context.html, 0, 300)

        {:ok, context}
      end

      then_ "and nothing suggests the agent will ignore it", context do
        refute context.html =~ ~r/withdrawn|cancelled|not delivered/i,
               "the view still describes the message as withdrawn, so the record and " <>
                 "the agent disagree about what it was told"

        {:ok, context}
      end
    end
  end
end
