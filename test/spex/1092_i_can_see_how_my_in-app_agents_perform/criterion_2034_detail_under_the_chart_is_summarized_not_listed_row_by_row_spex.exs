defmodule CodeMySpecSpex.Story1092.Criterion2034Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2034 -- Detail under the chart is summarized, not listed row
  by row.
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
    Fixtures.use_recording_transport()
  end

  spex "The chart's detail is a summary, not a row for each nudge",
    criterion: 2034 do
    scenario "a story received three separate nudges" do
      given_ "a released story with an agent nudged three separate times", context do
        {:ok, main_copy} =
          CodeMySpec.WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = CodeMySpec.WorkingCopies.designate_main(context.scope, main_copy.id)

        reply = join_working_copy(context, "/tmp/spex-2034", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_story(scope,
            title: "Nudged three times",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2034")

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)
        refute resp.isError, inspect(resp)

        for reason <- [
              "check the migration order",
              "double-check the index",
              "re-run the suite"
            ] do
          {:reply, sent, _frame} =
            MessageAgent.execute(%{agent_id: agent.id, message: reason}, frame)

          refute sent.isError, inspect(sent)
        end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:story, story)}
      end

      when_ "I look at the performance page", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart's detail summarizes the three nudges as one count", context do
        assert context.html =~ "Nudges: 3",
               "the chart's detail does not summarize the three nudges as one count"

        {:ok, context}
      end

      then_ "and it is not a row for each one", context do
        refute context.html =~ "chart-detail-row",
               "the chart's detail lists a row per nudge instead of summarizing them"

        {:ok, context}
      end
    end
  end
end
