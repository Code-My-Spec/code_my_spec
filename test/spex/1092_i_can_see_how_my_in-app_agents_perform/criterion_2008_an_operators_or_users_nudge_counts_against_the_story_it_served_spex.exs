defmodule CodeMySpecSpex.Story1092.Criterion2008Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2008 -- An operator's or user's nudge counts against the story
  it served.

  Rule: Every manual intervention (operator or user nudge, approval,
  restart) is counted against the story it served.

  Restarting an agent working a story is driven through `RestartAgent`, the
  main agent's own tool for it -- the real surface this app has for "a
  person made an agent start over"; there is no separate literal
  user-initiated restart action.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
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

  spex "Restarting the agent working a story counts the restart against that story",
       criterion: 2008 do
    scenario "the user restarted an agent while it worked a story" do
      given_ "a released story with a coding agent working it", context do
        reply = join_working_copy(context, "/tmp/spex-2008", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_story(scope,
            title: "Restarted mid-flight",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, _resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2008")

        {:ok,
         context |> Map.put(:scope, scope) |> Map.put(:story, story) |> Map.put(:agent, agent)}
      end

      when_ "the agent is restarted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, restarted, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent.id, reason: "stuck on a stale read"},
            frame
          )

        refute restarted.isError, inspect(restarted)
        {:ok, context}
      end

      then_ "the restart is counted as a manual intervention on that story", context do
        {:ok, _index, html} = live(context.conn, index_path(context))

        assert html =~ context.story.title and html =~ "restart",
               "the agent's restart is not shown as a manual intervention against the story it was working"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and it names who intervened and why", context do
        assert context.html =~ "stuck on a stale read",
               "the recorded intervention does not name why the agent was restarted"

        {:ok, context}
      end
    end
  end
end
