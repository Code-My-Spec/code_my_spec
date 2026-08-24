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
  channel.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Watching is live, not retrospective" do
    scenario "I watch the work arrive" do
      given_ "an agent I have asked to do something that takes a while", context do
        copy = CodeMySpec.TempFile.dir("spex_2893")
        File.mkdir_p!(copy)

        agent = Fixtures.start_agent_for(context.scope, working_copy: copy)
        start_agent(agent.id, working_copy: copy)

        conversation = Fixtures.agent_conversation(context.scope, agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation/#{conversation.id}"
          )

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:live, live)
         |> Map.put(:conversation, conversation)}
      end

      when_ "it takes a step while I am watching", context do
        # One step of a turn, reported the way the machine reports one — not the
        # finished turn. If only completed turns are carried, nothing arrives
        # here and the criterion fails, which is the point.
        Fixtures.agent_reports_step(context.scope, context.agent, %{
          "type" => "tool_use",
          "name" => "read",
          "input" => %{"file_path" => "mix.exs"}
        })

        {:ok, context}
      end

      then_ "its steps appear while it is still working", context do
        html = render(context.live)

        assert html =~ "read",
               "the step did not reach the page while the agent was mid-turn. " <>
                 "Watching that only updates when a turn finishes is watching that " <>
                 "shows you an agent went wrong after it has finished going wrong."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and I do not have to reload to see them", context do
        refute context.html == "",
               "the page rendered nothing, so this cannot distinguish a live update " <>
                 "from an empty page"

        assert Fixtures.conversation_messages(context.scope, context.conversation) != [],
               "the step reached the page but was not recorded, so a reload would " <>
                 "lose it — live and durable are both required, and this is the " <>
                 "durable half"

        {:ok, context}
      end
    end
  end
end
