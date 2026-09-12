defmodule CodeMySpecSpex.Story1024.Criterion2895Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2895 — I redirect an agent without a terminal.

  Rule: A message I send reaches the agent.

  The half that was missing outright. The view had a send box already, gated on
  a running agent for the copy, and submitting it called
  `Conversations.add_message(:operator, ...)` and stopped there. The message was
  recorded and never delivered.

  That was correct under the previous design — a Pi lane collected operator
  messages when it settled, through the stop hook. Nothing does that now, so
  the box was live and went nowhere.

  Asked of the provider rather than of the transcript. A conversation row only
  proves the server wrote something down; the claim is that the text reached
  the loop that acts on it, and those two came apart in exactly the way this
  criterion exists to catch.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CmsHarnessTest.HeldProvider
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

  spex "Talking to an agent from where you watch it" do
    scenario "I redirect an agent without a terminal" do
      given_ "an agent running on my working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2895")
        RealDisk.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2895", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        start_agent_with_provider(agent.id, working_copy: copy, report_to: socket)

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:copy, copy)}
      end

      when_ "I send it a message from its conversation", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: conversation.id]}"
          )

        html =
          live
          |> form("form[phx-submit=send_message]", %{"message" => "say READY and nothing else"})
          |> render_submit()

        {:ok,
         context
         |> Map.put(:html, html)
         |> Map.put(:live, live)
         |> Map.put(:conversation, conversation)}
      end

      then_ "the agent receives it and acts on it", context do
        assert agent_received?(context.agent.id, "say READY"),
               "the message was recorded in the conversation and never delivered. " <>
                 "That is the failure this criterion exists for: the send box looks " <>
                 "like it worked, the operator believes the agent was told, and the " <>
                 "agent carries on doing whatever it was doing."

        {:ok, context}
      end

      then_ "and the box does not still hold what I just sent", context do
        # Found in use, not here: the input had no rendered `value`, so the DOM
        # patch had nothing to set and the typed text survived the submit. It
        # sits there looking unsent, and the next thing anyone does is send it
        # again — two turns, two answers, and a transcript that reads as though
        # the page duplicated everything. It had.
        assert render(context.live) =~ ~s(name="message" value=""),
               "the send box renders no empty value, so what was typed outlives " <>
                 "the submit and invites a second send of the same message"

        {:ok, context}
      end

      then_ "and its answer appears in the same conversation", context do
        eventually(fn ->
          {:ok, _reloaded, html} =
            live(
              context.conn,
              ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: context.conversation.id]}"
            )

          assert html =~ "say READY",
                 "the operator's own message is not in the transcript they are " <>
                   "reading, so the exchange has no record of what was asked"

          assert html =~ HeldProvider.answer(),
                 "the agent's answer went somewhere other than the conversation the " <>
                   "operator is watching, so the exchange reads as one-sided"
        end)

        {:ok, context}
      end
    end
  end
end
