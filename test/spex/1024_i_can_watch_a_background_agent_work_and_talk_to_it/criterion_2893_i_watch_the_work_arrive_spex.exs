defmodule CodeMySpecSpex.Story1024.Criterion2893Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2893 — I watch the work arrive.

  Rule: An agent's work appears as it happens, not only when the turn ends.

  Today an agent reports nothing at all: the engine runs turns and none of them
  reach the server, so a working agent's conversation looks identical to an
  idle one. This criterion is the first half of fixing that, and the harder
  half — not "the turn shows up afterwards" but "the steps show up while it is
  still going".

  The distinction is the whole point of watching. A turn that appears complete
  at the end tells you what happened; steps arriving as they happen let you see
  an agent going the wrong way while there is still something to do about it.

  The decision on how: a channel push per turn event, on the existing project
  channel. So the `when_` is that push — the message a machine actually sends,
  on the channel it actually sends it on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
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

  spex "Watching is live, not retrospective" do
    scenario "I watch the work arrive" do
      given_ "an agent I have asked to do something that takes a while", context do
        copy = CodeMySpec.TempFile.dir("spex_2893")
        File.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2893", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        conversation = Fixtures.agent_conversation(context.scope, agent)

        {:ok, live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        # Nothing has happened yet, and the page must say that rather than
        # warn. It used to announce "Turns were taken but not recorded" over
        # any empty transcript — a warning about a real failure, raised over a
        # working system, as the first thing anyone sees after starting an
        # agent. Watching that cries wolf at rest is not watching.
        refute html =~ "not recorded",
               "the page claims this agent's turns were lost before it has taken " <>
                 "one. An operator reading that goes looking for a defect that is " <>
                 "not there, and stops believing the sentence when it is."

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:socket, socket)
         |> Map.put(:live, live)
         |> Map.put(:conversation, conversation)}
      end

      when_ "it takes a step while I am watching", context do
        # One step of a turn, reported the way the machine reports one — not the
        # finished turn. If only completed turns are carried, nothing arrives
        # here and the criterion fails, which is the point.
        ref =
          Phoenix.ChannelTest.push(context.socket, "agent_turn_event", %{
            "agent_id" => context.agent.id,
            "event" => %{"kind" => "tool_use", "text" => "read lib/mix.exs"}
          })

        # Replied to before anything is asked of the page, so what follows is a
        # claim about what the server did with the step rather than a race with
        # it still arriving.
        Phoenix.ChannelTest.assert_reply(ref, :ok)

        {:ok, context}
      end

      then_ "its steps appear while it is still working", context do
        html = render(context.live)

        assert html =~ "read lib/mix.exs",
               "the step did not reach the page while the agent was mid-turn. " <>
                 "Watching that only updates when a turn finishes is watching that " <>
                 "shows you an agent went wrong after it has finished going wrong."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and I do not have to reload to see them", context do
        # The other half: live is not enough on its own, because a page that
        # renders what it was handed and stores nothing loses it on refresh.
        # This is the same page, opened again from scratch.
        {:ok, _reloaded, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{context.conversation.id}"
          )

        assert html =~ "read lib/mix.exs",
               "the step reached the page but was not recorded, so a reload would " <>
                 "lose it — live and durable are both required, and this is the " <>
                 "durable half"

        {:ok, context}
      end
    end
  end
end
