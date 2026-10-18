defmodule CodeMySpecSpex.Story1092.Criterion2031Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2031 -- Story starts and promotions appear on the chart as
  events, not lines.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.PromotionHelpers, except: [promote: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story's start and its promotion appear on the chart as events, not as chart lines",
    criterion: 2031 do
    scenario "a story started this week and was promoted this week" do
      given_ "a story that started and was then promoted", context do
        context = a_promotable_project(context)
        story = a_promotable_story(context, title: "Started then promoted")

        Fixtures.running_agent(context.scope, role: "coding", working_copy: context.agent_root)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        resp =
          ToolLibrary.run(
            "set_active_story",
            %{story_number: story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, resp), inspect(resp)

        context = analyzers_are_current(context)

        {:reply, promoted, _frame} = PromoteSync.execute(%{story_number: story.number}, frame)
        refute promoted.isError, inspect(promoted)

        {:ok, Map.put(context, :story, story)}
      end

      when_ "I look at the performance page", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the story's start is on the chart as an event", context do
        assert context.html =~ "story_start",
               "the story's start does not appear on the chart"

        {:ok, context}
      end

      then_ "and the promotion is on the chart as a separate event, not a line", context do
        assert context.html =~ "promotion",
               "the promotion does not appear on the chart"

        assert context.html =~ "events",
               "events are not carried as their own collection on the chart, separate from the metric lines"

        {:ok, context}
      end
    end
  end
end
