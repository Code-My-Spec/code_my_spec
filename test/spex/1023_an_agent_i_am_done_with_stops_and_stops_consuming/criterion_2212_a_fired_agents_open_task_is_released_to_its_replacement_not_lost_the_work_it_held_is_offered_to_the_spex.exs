defmodule CodeMySpecSpex.Story1023.Criterion2212Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2212 — A fired agent's open task is released to its replacement,
  not lost: the work it held is offered to the new agent.

  No scenario was recorded against this criterion; this one is a mechanical
  translation of its title. A fired agent's seat is empty, but the work it
  was holding when it was fired should not disappear with it — a teammate of
  the same role on duty is the one it is offered to.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A fired agent's open work is offered to its replacement", criterion: 2212 do
    scenario "A fired agent's open task is released to its replacement, not lost" do
      given_ "an agent holding an open task, and a replacement of the same role on duty",
             context do
        story = Fixtures.authored_story(context.scope, "Customers can cancel a subscription")

        target_copy = CodeMySpec.TempFile.dir("spex_2212_target")
        replacement_copy = CodeMySpec.TempFile.dir("spex_2212_replacement")
        RealDisk.mkdir_p!(target_copy)
        RealDisk.mkdir_p!(replacement_copy)

        target =
          Fixtures.running_agent(context.scope, role: "coding", working_copy: target_copy)

        replacement =
          Fixtures.running_agent(context.scope, role: "coding", working_copy: replacement_copy)

        start_agent(target.id, working_copy: target.working_copy)
        start_agent(replacement.id, working_copy: replacement.working_copy)

        {_agent, _task} =
          Fixtures.agent_task_fixture(context.scope, target,
            requirement_name: "implementation_file",
            story_id: story.id
          )

        {:ok,
         context
         |> Map.put(:story, story)
         |> Map.put(:target, target)
         |> Map.put(:replacement, replacement)}
      end

      when_ "I fire the agent holding the task", context do
        {:ok, view, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.target.working_copy_id}"
          )

        view
        |> element("[data-agent-id='#{context.target.id}'] [data-test='fire-agent']")
        |> render_click()

        view
        |> element("[data-agent-id='#{context.target.id}'] [data-test='confirm-fire-agent']")
        |> render_click()

        {:ok, context}
      end

      then_ "the work it held is offered to the new agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListAgentWork.execute(%{}, frame)

        text = response_text(listing)

        assert text =~ context.replacement.id and text =~ context.story.title,
               "the fired agent's open task on \"#{context.story.title}\" is not showing " <>
                 "as offered to its replacement — the work it held looks lost rather " <>
                 "than released. listing: #{text}"

        {:ok, context}
      end

      then_ "and not lost", context do
        refute running?(context.target.id),
               "the fired agent is still running — firing it should have ended it"

        {:ok, context}
      end
    end
  end
end
