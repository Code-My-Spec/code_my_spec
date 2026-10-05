defmodule CodeMySpecSpex.Story1092.Criterion2005Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2005 -- Each team shows its first-pass rate.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A team's first-pass rate is the share of its stories QA passed on the first attempt",
       criterion: 2005 do
    scenario "a team whose stories went to QA over a period" do
      given_ "one story that passed QA first time and one that took two rounds", context do
        reply = join_working_copy(context, "/tmp/spex-2005", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        qa = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-2005")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: qa.id}}

        clean = qa_a_story(scope, asking, "Passed first time", [
          %{status: "pass", note: "all good"}
        ])

        reworked =
          qa_a_story(scope, asking, "Took two rounds", [
            %{status: "fail", note: "broke on save"},
            %{status: "pass", note: "fixed"}
          ])

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:clean, clean)
         |> Map.put(:reworked, reworked)}
      end

      when_ "I look at the team", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "I see the share of stories that passed QA on the first attempt", context do
        assert context.html =~ "50%",
               "the team's first-pass rate (1 of 2 stories passed first time) is not shown as 50%"

        {:ok, context}
      end
    end
  end

  defp qa_a_story(scope, asking, title, rounds) do
    story =
      StoryHelpers.create_story(scope,
        title: title,
        description: "As a user, I want this story done.",
        acceptance_criteria: ["It works"]
      )

    {:reply, _resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, asking)

    {:reply, started, _frame} =
      StartTask.execute(
        %{requirement_name: "qa_complete", entity_type: "story", entity_id: to_string(story.number)},
        asking
      )

    refute started.isError, inspect(started)
    [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))

    Enum.each(rounds, fn round -> submit_round(asking, story, task_id, round) end)

    story
  end

  defp submit_round(asking, _story, task_id, %{status: "pass", note: note}) do
    {:reply, response, _frame} =
      SubmitQaResult.execute(
        %{
          task_id: task_id,
          status: "pass",
          scenarios: [%{name: "it works", status: "pass", observation: note}],
          issue_ids: []
        },
        asking
      )

    refute response.isError, inspect(response)
  end

  defp submit_round(asking, story, task_id, %{status: "fail", note: note}) do
    {:reply, issue, _frame} =
      CreateIssue.execute(
        %{title: note, severity: "high", description: note, story_number: story.number},
        asking
      )

    [_, issue_id] = Regex.run(~r/\(ID: ([0-9a-f-]{36})\)/, response_text(issue))

    {:reply, response, _frame} =
      SubmitQaResult.execute(
        %{
          task_id: task_id,
          status: "fail",
          scenarios: [%{name: "it works", status: "fail", observation: note}],
          issue_ids: [issue_id]
        },
        asking
      )

    refute response.isError, inspect(response)
  end
end
