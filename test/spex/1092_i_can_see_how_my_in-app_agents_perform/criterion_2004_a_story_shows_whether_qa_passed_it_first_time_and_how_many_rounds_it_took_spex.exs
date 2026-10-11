defmodule CodeMySpecSpex.Story1092.Criterion2004Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2004 -- A story shows whether QA passed it first time and how
  many rounds it took.
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
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story that failed QA before passing shows every round and no first-time pass",
    criterion: 2004 do
    scenario "a story that failed QA twice before passing" do
      given_ "a story QA'd three times, failing the first two rounds", context do
        {:ok, main_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = WorkingCopies.designate_main(context.scope, main_copy.id)

        {reply, socket} = join_working_copy_socket(context, "/tmp/spex-2004", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        ComponentHelpers.create(scope,
          name: "Example2004",
          type: "context",
          module_name: "CodeMySpecSpex.Example2004",
          description: "Fixture component for criterion 2004."
        )

        story =
          StoryHelpers.create_and_link(scope, "CodeMySpecSpex.Example2004",
            title: "Took three rounds",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        fixture_context = %{scope: scope, environment: context.environment}

        %{persona_id: persona_id} = ProjectStateFixtures.apply_persona(fixture_context)

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(scope, story, persona_id: persona_id)

        :ok = ProjectStateFixtures.apply_bdd_spec_for_story(fixture_context, story)

        {:ok, _} =
          Stories.set_qa_ready(
            scope,
            Stories.get_story!(scope, story.id),
            String.duplicate("a", 40)
          )

        qa = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-2004")
        coder = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2004")
        coding = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}
        asking = %Frame{assigns: %{current_scope: scope, agent_id: qa.id}}

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)
        refute resp.isError, inspect(resp)

        {:reply, started, _frame} =
          start_qa(asking, story, socket)

        refute started.isError, inspect(started)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))

        {:reply, issue_1, _frame} =
          CreateIssue.execute(
            %{
              title: "Round one finding",
              severity: "high",
              description: "the save button does nothing",
              story_number: story.number
            },
            asking
          )

        [_, issue_1_id] = Regex.run(~r/\(ID: ([0-9a-f-]{36})\)/, response_text(issue_1))

        {:reply, round_1, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: task_id,
              status: "fail",
              scenarios: [
                %{name: "save", status: "fail", observation: "save button does nothing"}
              ],
              issue_ids: [issue_1_id]
            },
            asking
          )

        refute round_1.isError, inspect(round_1)

        {:reply, accepted_1, _frame} =
          AcceptIssue.execute(%{issue_id: issue_1_id, category: "bug"}, asking)

        refute accepted_1.isError, inspect(accepted_1)

        {:reply, submitted_1, _frame} =
          SubmitStoryIssue.execute(
            %{
              issue_id: issue_1_id,
              revision: String.duplicate("b", 40),
              evidence: "Fixed the save button's no-op handler; regression test passed."
            },
            coding
          )

        refute submitted_1.isError, inspect(submitted_1)

        {:ok, _} =
          Stories.set_qa_ready(
            scope,
            Stories.get_story!(scope, story.id),
            String.duplicate("b", 40)
          )

        {:reply, resumed_1, _frame} =
          start_qa(asking, story, socket)

        refute resumed_1.isError, inspect(resumed_1)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(resumed_1))

        {:reply, issue_2, _frame} =
          CreateIssue.execute(
            %{
              title: "Round two finding",
              severity: "high",
              description: "the save button now errors instead",
              story_number: story.number
            },
            asking
          )

        [_, issue_2_id] = Regex.run(~r/\(ID: ([0-9a-f-]{36})\)/, response_text(issue_2))

        {:reply, round_2, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: task_id,
              status: "fail",
              scenarios: [%{name: "save", status: "fail", observation: "save button now errors"}],
              issue_ids: [issue_2_id]
            },
            asking
          )

        refute round_2.isError, inspect(round_2)

        {:reply, accepted_2, _frame} =
          AcceptIssue.execute(%{issue_id: issue_2_id, category: "bug"}, asking)

        refute accepted_2.isError, inspect(accepted_2)

        {:reply, submitted_2, _frame} =
          SubmitStoryIssue.execute(
            %{
              issue_id: issue_2_id,
              revision: String.duplicate("c", 40),
              evidence: "Fixed the save button's error handling; regression test passed."
            },
            coding
          )

        refute submitted_2.isError, inspect(submitted_2)

        {:ok, _} =
          Stories.set_qa_ready(
            scope,
            Stories.get_story!(scope, story.id),
            String.duplicate("c", 40)
          )

        {:reply, resumed_2, _frame} =
          start_qa(asking, story, socket)

        refute resumed_2.isError, inspect(resumed_2)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(resumed_2))

        {:reply, round_3, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: task_id,
              status: "pass",
              scenarios: [%{name: "save", status: "pass", observation: "saves correctly now"}],
              issue_ids: []
            },
            asking
          )

        refute round_3.isError, inspect(round_3)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:story, story)}
      end

      when_ "I look at its performance", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "it shows three QA rounds and no first-time pass", context do
        assert context.html =~ "3",
               "the story's three QA rounds are not shown"

        refute Regex.match?(~r/>first-time pass</, context.html) and
                 context.html =~ context.story.title,
               "a story that failed QA twice is shown as a first-time pass"

        assert context.html =~ "no first-time pass",
               "a story that failed QA twice should be shown as no first-time pass"

        {:ok, context}
      end

      then_ "and each failed round names what QA found", context do
        assert context.html =~ "save button does nothing",
               "the first failed round does not name what QA found"

        assert context.html =~ "save button now errors",
               "the second failed round does not name what QA found"

        {:ok, context}
      end
    end
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
