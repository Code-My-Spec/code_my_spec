defmodule CodeMySpecSpex.Story1080.Criterion1868Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1868 — Told its blocker cleared while its task's requirement is
  still waiting on something, an agent does not start the task, and says
  what it is waiting on.

  `Work.wake_released/6`'s own comment: "A released task whose requirement
  still waits on something is not offered: 'resume it' would send the agent
  to `start_task` for a task it is refused. It is told what the task waits
  on instead." `waiting_notice/3` is the real text this asserts on.

  Per product's ruling: `still_waiting?/2` only recognizes a task on the
  agent's own story whose node has left that story's actionable set -- a
  component's own dependency graph is out of scope for this criterion. Built
  on a coding-role, story-scoped task (`bdd_specs_exist`, prerequisite id 5
  in requirement_definition_data.ex -- `three_amigos_complete`, not
  `qa_setup`; an earlier version of this spex wrongly assumed `qa_setup`
  (id 14, prerequisite [6], a separate QA-role chain) sat upstream of it,
  confirmed by main's diagnosis and this module's own prerequisite ids).
  `three_amigos_complete`'s own check, `BddRulesChecker.sealed?/2`, reads
  nothing but `story.three_amigos_sealed`. Reopening a sealed story has no
  product-facing door to walk back through the way sealing it does
  (`Fixtures.seal_three_amigos/2`), so `Fixtures.unseal_three_amigos/2`
  writes the field the one way available -- through the Fixtures bridge,
  not a direct context call, so this scenario's own given_ still drives the
  app the way `test/code_my_spec/spex_givens_test.exs` requires.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A released task still unsatisfied upstream is not resumed, and says what it waits on",
       criterion: 1868 do
    scenario "the story's three-amigos seal is undone while its design task is blocked" do
      given_ "a coder started bdd_specs_exist, actionable, and blocked it on a question",
             context do
        context =
          context
          |> FullSatisfactionFixtures.apply_without_three_amigos()
          |> FullSatisfactionFixtures.apply_three_amigos_artifacts()

        {:ok, _pid} = GraphWatcher.ensure_watching(context.scope)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story.number)
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        blocker = Fixtures.question_id_from(response_text(asked))
        {:ok, Map.merge(context, %{coder: coder.id, task_id: task_id, blocker: blocker})}
      end

      given_ "three_amigos_complete, its task's own prerequisite, is withdrawn again", context do
        story = Stories.get_story_by_number!(context.scope, context.story.number)
        :ok = Fixtures.unseal_three_amigos(context.scope, story)
        :ok = GraphWatcher.settle(context.scope)

        {:ok, agent} = CodeMySpec.Agents.AgentsRepository.fetch_agent(context.scope, context.coder)

        assert CodeMySpec.Agents.Work.claimable_work(context.scope, agent) == [],
               "bdd_specs_exist was still claimable right after three_amigos_complete was withdrawn"

        {:ok, context}
      end

      when_ "the question that blocked the task is answered", context do
        :ok = user_answers(context, context.blocker, "Left")
        id = context.coder
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # note_released/2 (Work.wake_released/6's waiting branch) only writes
        # the conversation -- it never offers a turn, so there is nothing to
        # assert_receive. The write lands off the caller's process
        # (Agents.Events' @task_released handler runs wake_released inside
        # Task.Supervisor.start_child), hence the retry.
        notice =
          eventually(fn ->
            {:reply, response, _frame} = ReadAgentConversation.execute(%{agent_id: id}, frame)
            text = response_text(response)
            assert text =~ "is not ready to resume", text
            text
          end)

        {:ok, Map.put(context, :notice, notice)}
      end

      then_ "the agent is not told to start_task on it", context do
        refute context.notice =~ "start_task", context.notice
        {:ok, context}
      end

      then_ "and is told it is not ready to resume, with what it is still waiting on", context do
        assert context.notice =~ "is not ready to resume", context.notice
        assert context.notice =~ "Do not start it yet", context.notice
        assert context.notice =~ "it is offered to you when it opens", context.notice
        {:ok, context}
      end

      then_ "once three_amigos_complete returns, the same task is offered to start_task", context do
        story = Stories.get_story_by_number!(context.scope, context.story.number)
        :ok = Fixtures.seal_three_amigos(context.scope, story)
        :ok = GraphWatcher.settle(context.scope)
        id = context.coder

        assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000
        assert prompt =~ "resume task #{context.task_id}"
        {:ok, context}
      end
    end
  end
end
