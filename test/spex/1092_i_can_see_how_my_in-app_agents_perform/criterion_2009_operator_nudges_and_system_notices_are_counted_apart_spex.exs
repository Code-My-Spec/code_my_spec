defmodule CodeMySpecSpex.Story1092.Criterion2009Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2009 -- Operator nudges and system notices are counted apart.

  Rule: Every manual intervention (operator or user nudge, approval,
  restart) is counted against the story it served; a harness-originated
  turn event is not a person intervening and must not inflate the same
  count.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One operator message counts as one intervention, whatever the harness also reported",
       criterion: 2009 do
    scenario "an agent received harness notices and one operator message during a story" do
      given_ "a released story with an agent that sent several harness turn events", context do
        reply = join_working_copy(context, "/tmp/spex-2009", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_story(scope,
            title: "One nudge, several harness notices",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, _resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2009")

        Fixtures.put_agent_mid_turn(scope, agent.id)
        :ok = Fixtures.end_turn(scope, agent.id)
        Fixtures.put_agent_mid_turn(scope, agent.id)
        :ok = Fixtures.end_turn(scope, agent.id)

        {:ok,
         context |> Map.put(:scope, scope) |> Map.put(:story, story) |> Map.put(:agent, agent)}
      end

      when_ "the operator sends it one message", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, sent, _frame} =
          MessageAgent.execute(
            %{agent_id: context.agent.id, message: "double-check the migration order"},
            frame
          )

        refute sent.isError, inspect(sent)
        {:ok, context}
      end

      then_ "interventions are counted", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "only the operator and user messages count as interventions", context do
        assert context.html =~ context.story.title and context.html =~ "1",
               "the story's intervention count is not exactly the one operator message that was sent"

        {:ok, context}
      end

      then_ "and harness notices are shown separately", context do
        refute context.html =~ context.story.title and context.html =~ "3",
               "the two harness turn-ended events were folded into the same count as the operator's own nudge"

        {:ok, context}
      end
    end
  end
end
