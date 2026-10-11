defmodule CodeMySpecSpex.Story1092.Criterion2005Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2005 -- Each team shows its first-pass rate.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import Phoenix.ChannelTest
  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.SubmitStoryIssue
  alias CodeMySpec.McpServers.Qa.Tools.SubmitQaResult
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.StorySliceHelpers
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
        {:ok, main_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = WorkingCopies.designate_main(context.scope, main_copy.id)

        {reply, socket} = join_working_copy_socket(context, "/tmp/spex-2005", "the checkout")
        scope = StorySliceHelpers.scope_for_copy(context, reply.working_copy_id, "/tmp/spex-2005")
        context = Map.put(context, :copy_socket, socket)

        clean =
          qa_a_story(%{context | scope: scope}, "Passed first time", [
            %{status: "pass", note: "all good"}
          ])

        reworked =
          qa_a_story(%{context | scope: scope}, "Took two rounds", [
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

  defp qa_a_story(context, title, rounds) do
    scope = context.scope
    module_name = "CodeMySpecSpex.Example2005#{System.unique_integer([:positive])}"

    ComponentHelpers.create(scope,
      name: module_name,
      type: "context",
      module_name: module_name,
      description: "Fixture component for criterion 2005."
    )

    story =
      StoryHelpers.create_and_link(scope, module_name,
        title: title,
        description: "As a user, I want this story done.",
        acceptance_criteria: ["It works"]
      )

    %{persona_id: persona_id} = ProjectStateFixtures.apply_persona(context)
    :ok = ProjectStateFixtures.apply_three_amigos_for_story(scope, story, persona_id: persona_id)
    :ok = ProjectStateFixtures.apply_bdd_spec_for_story(context, story)

    {:ok, _} =
      Stories.set_qa_ready(scope, Stories.get_story!(scope, story.id), String.duplicate("a", 40))

    coder = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2005")
    coding = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}
    qa = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-2005")
    asking = %Frame{assigns: %{current_scope: scope, agent_id: qa.id}}

    {:reply, sas_resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, asking)
    refute sas_resp.isError, inspect(sas_resp)

    Enum.each(rounds, fn round ->
      {:reply, started, _frame} =
        start_qa(asking, story, context.copy_socket)

      refute started.isError, inspect(started)
      [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))
      submit_round(asking, coding, story, task_id, round)
    end)

    story
  end

  defp submit_round(asking, _coding, _story, task_id, %{status: "pass", note: note}) do
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

  defp submit_round(asking, coding, story, task_id, %{status: "fail", note: note}) do
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

    {:reply, accepted, _} = AcceptIssue.execute(%{issue_id: issue_id, category: "bug"}, asking)
    refute accepted.isError, inspect(accepted)

    {:reply, submitted, _} =
      SubmitStoryIssue.execute(
        %{
          issue_id: issue_id,
          revision: String.duplicate("b", 40),
          evidence: "Fixed the reported save failure; regression test passes."
        },
        coding
      )

    refute submitted.isError, inspect(submitted)
    scope = asking.assigns.current_scope

    {:ok, _} =
      Stories.set_qa_ready(scope, Stories.get_story!(scope, story.id), String.duplicate("b", 40))
  end

  defp start_qa(asking, story, socket) do
    task =
      Task.async(fn ->
        StartTask.execute(
          %{
            requirement_name: "qa_complete",
            entity_type: "story",
            entity_id: to_string(story.number)
          },
          asking
        )
      end)

    with_task_cleanup(task, fn ->
      assert_push("ensure_app_running", %{"ref" => ref}, 5_000)

      reply_ref =
        Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
          "ref" => ref,
          "status" => "ok",
          "app_status" => "serving",
          "app_url" => "http://127.0.0.1:4100",
          "app_commit" => "cafef00d"
        })

      assert_reply(reply_ref, :ok, _, 5_000)
      Task.await(task, 5_000)
    end)
  end
end
