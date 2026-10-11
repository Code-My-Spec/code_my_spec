defmodule CodeMySpecSpex.Story1092.Criterion2012Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2012 -- Each team's promoted stories are counted over a
  period.

  Rule: Story throughput is shown per team over a period.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.PromotionHelpers, except: [promote: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A team's promoted stories over a week are counted as its throughput",
       criterion: 2012 do
    scenario "two teams promoted stories over a week" do
      given_ "one story promoted this week", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, title: "Landed this week")

        Fixtures.running_agent(context.scope, role: "coding", working_copy: context.agent_root)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)
        refute resp.isError, inspect(resp)

        context = analyzers_are_current(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "its team promotes it", context do
        response = promote_now(context, context.story.number)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "I see how many stories and issue fixes each team landed for that week", context do
        {:ok, _index, html} = live(context.conn, index_path(context))

        assert html =~ context.agent.working_copy_id,
               "the promoting team's own identity is not shown"

        assert html =~ "Promoted: 1",
               "the one story this team promoted this week is not counted in its throughput"

        {:ok, context}
      end
    end
  end

  # `PromotionHelpers.promote/2` goes through the async `Promote` tool, which
  # only queues now and tells the caller nothing about when the batch lands --
  # fine for the promotion-queue criteria that drive the gate themselves, but
  # this criterion only cares what a landed promotion looks like in the
  # report, so it uses the same synchronous door criterion 1394 does.
  defp promote_now(context, story_number) do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{story_number: story_number}, frame)
    response
  end
end
