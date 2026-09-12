defmodule CodeMySpecSpex.Story1024.Criterion2897Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2897 — Something I said mid-turn is not dropped.

  Rule: A message sent while the agent is busy is delivered when it settles,
  rather than lost.

  Mid-turn is when you are most likely to send something, because watching an
  agent work is what makes you want to redirect it. So "busy" cannot mean the
  message evaporates.

  `Alloy.send_message/3` answers `{:error, :busy}` upstream, which makes
  refusing the easy implementation and losing the message the easy accident.
  The PM's decision is that it waits: accepted, visibly pending, delivered when
  the turn ends.

  The premise is a turn genuinely in flight — a real agent waiting on a real
  provider that this criterion is holding open. An agent told it is busy would
  prove nothing about an agent that is.
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

  spex "Busy is not a reason to lose it" do
    scenario "Something I said mid-turn is not dropped" do
      given_ "an agent in the middle of a turn", context do
        copy = CodeMySpec.TempFile.dir("spex_2897")
        RealDisk.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2897", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        start_agent_with_provider(agent.id, working_copy: copy, report_to: socket)
        begin_turn(agent.id)

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "I send it a message", context do
        conversation = Fixtures.agent_conversation(context.scope, context.agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: conversation.id]}"
          )

        html =
          live
          |> form("form[phx-submit=send_message]", %{"message" => "also update the README"})
          |> render_submit()

        {:ok, context |> Map.put(:html, html) |> Map.put(:conversation, conversation)}
      end

      then_ "the message is accepted and shown as waiting", context do
        assert context.html =~ ~r/waiting|queued|pending/i,
               "a message sent mid-turn shows no pending state, so the operator " <>
                 "cannot tell whether it was taken, refused, or dropped. Got: " <>
                 String.slice(context.html, 0, 300)

        {:ok, context}
      end

      then_ "and the agent acts on it once the current turn finishes", context do
        finish_turn(context.agent.id)

        assert agent_received?(context.agent.id, "also update the README"),
               "the turn ended and the queued message was never delivered. Refusing " <>
                 "while busy and forgetting are indistinguishable to whoever sent it, " <>
                 "and this is the moment an operator is most likely to be redirecting " <>
                 "the agent."

        {:ok, context}
      end
    end
  end
end
