defmodule CodeMySpecSpex.Story1017.Criterion2417Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2417 — Open questions survive an internal agent restart in ask order.

  Claim and ask twice through MCP, then stop and relaunch the real local
  process under the same durable identity. A fresh tool frame must recover
  both questions and their task links without session history or cached ids.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  spex "A restarted internal agent recovers its own open questions and task links",
    criterion: 910 do
    scenario "Two questions remain in ask order after the local process is replaced" do
      given_ "a connected checkout has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_2417")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a durable coding agent has asked about two independently claimed stories",
             context do
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        base_url = HeldProvider.start()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        questions =
          Enum.map(["Refund period", "Receipt format"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent work with a durable unanswered decision",
                acceptance_criteria: ["The chosen behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            {:reply, started, _} =
              StartTask.execute(
                %{
                  requirement_name: "bdd_specs_exist",
                  entity_type: "story",
                  entity_id: to_string(story.number)
                },
                frame
              )

            refute started.isError, response_text(started)
            task_id = extract_task_id!(started)

            {:reply, asked, _} =
              AskUserQuestion.execute(
                %{
                  task_id: task_id,
                  questions: [
                    %{
                      question: "Which #{title} should we use?",
                      options: [%{label: "Keep existing"}, %{label: "Change it"}]
                    }
                  ]
                },
                frame
              )

            refute asked.isError, response_text(asked)
            [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
            %{id: question_id, task_id: task_id, text: "Which #{title} should we use?"}
          end)

        {:ok, Map.merge(context, %{agent_id: agent.id, base_url: base_url, questions: questions})}
      end

      when_ "the agent process is stopped and explicitly restarted under the same identity",
            context do
        Machine.stop_agent(context.agent_id)
        assert {:error, :not_running} = Machine.status(context.agent_id)

        assert {:ok, _} =
                 Machine.start_agent(context.agent_id, context.copy, base_url: context.base_url)

        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.agent_id}}
        {:ok, Map.put(context, :restarted_frame, frame)}
      end

      then_ "a fresh listing recovers both unanswered questions in their original ask order",
            context do
        {:reply, listed, _} = ListUserQuestions.execute(%{}, context.restarted_frame)
        refute listed.isError, response_text(listed)
        text = response_text(listed)
        assert text =~ "2 open questions"
        [first, second] = context.questions

        assert text =~
                 ~r/#{Regex.escape(first.id)}.*#{Regex.escape(second.id)}/s

        Enum.each(context.questions, fn question ->
          assert text =~ question.text
          assert text =~ question.task_id
        end)

        {:ok, context}
      end

      then_ "the same two tasks remain blocked and restarting has not requested a model turn",
            context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.restarted_frame)
        refute tasks.isError, response_text(tasks)
        text = response_text(tasks)
        assert text =~ "# Tasks (2)"
        assert length(Regex.scan(~r/\[blocked\]/, text)) == 2
        refute text =~ "[active]"
        Enum.each(context.questions, fn question -> assert text =~ question.task_id end)
        assert HeldProvider.seen() == []
        {:ok, context}
      end
    end
  end
end
