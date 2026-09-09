defmodule CodeMySpecSpex.Story1024.Criterion2900Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2900 — I change my mind before it lands.

  Rule: A message waiting to be delivered can be taken back.

  The reason you send something mid-turn is that you are reacting to what you
  are watching. Reactions change — the agent recovers on its own, or you see
  what it is actually doing, or you think of something better. A queue you
  cannot take anything out of turns every reaction into a commitment.

  Taking it back has to be real rather than cosmetic: removing it from the view
  while the machine still holds it would be the worst version, because the
  operator now believes the agent will not see something it is about to act on.
  So the assertion is against the provider — what the agent was actually sent —
  and not against the page that cleared the row.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A queued message is not a commitment" do
    scenario "I change my mind before it lands" do
      given_ "a message of mine waiting for the agent to finish its turn", context do
        copy = CodeMySpec.TempFile.dir("spex_2900")
        RealDisk.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2900", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        start_agent_with_provider(agent.id, working_copy: copy, report_to: socket)
        begin_turn(agent.id)

        conversation = Fixtures.agent_conversation(context.scope, agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        live
        |> form("form[phx-submit=send_message]", %{"message" => "never mind this one"})
        |> render_submit()

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:live, live)
         |> Map.put(:conversation, conversation)}
      end

      when_ "I take it back", context do
        html =
          context.live
          |> element("[data-test=agent-withdraw-message]")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is not delivered", context do
        finish_turn(context.agent.id)

        refute agent_received?(context.agent.id, "never mind this one"),
               "the withdrawn message reached the agent anyway. Taking it back that " <>
                 "only clears the view is the worst version: the operator believes " <>
                 "the agent will not see something it is about to act on."

        {:ok, context}
      end

      then_ "and the agent carries on with what it was doing", context do
        assert running?(context.agent.id),
               "withdrawing a queued message stopped the agent. Taking back " <>
                 "something it never saw should not touch the work it is doing."

        {:ok, context}
      end
    end
  end
end
