defmodule CodeMySpecSpex.Story1059.Criterion3335Spex do
  @moduledoc """
  Approved whole-agent tap-out disables autonomous work, not durable reachability.
  Questions and recovery must respect that choice; explicit chat and deliberate
  re-enabling continue to use the existing agent.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [start_agent_with_provider: 2]
  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Whole-agent tap-out preserves the same reachable main agent" do
    scenario "Questions wait while chat and deliberate re-enabling remain available" do
      given_ "the user approves a task-free main agent's explicit null-task tap-out", context do
        context = given_a_staffed_checkout(context, "spex_3335")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}
        # Reported back over the checkout's own harness channel, which
        # `given_a_staffed_checkout/2` already joined and hands over as
        # `:harness_socket`. `Machine.start_agent/3` reports nowhere by
        # default: the machine ran real turns and the server heard about none
        # of them, so the transcript this criterion reads stayed at "Nothing
        # recorded yet" for a turn that demonstrably happened — a gap in the
        # premise reading as a product failure.
        start_agent_with_provider(main.id,
          working_copy: context.copy,
          report_to: context.harness_socket
        )

        HeldProvider.hold()
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(main.id)
        running_ids = Machine.running()
        {:reply, tapped, _} = TapOut.execute(%{task_id: nil}, main_frame)
        refute tapped.isError, response_text(tapped)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(tapped))
        {:ok, permission, _} = live(context.conn, "/app/permissions/#{request_id}")
        permission |> element("[data-test='approve-permission']") |> render_click()
        assert has_element?(permission, "[data-test='permission-resolved']", "approved")
        path = Fixtures.agent_conversation_path(context.scope, main)
        {:ok, view, _} = live(context.conn, path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: main_frame,
           coding_frame: coding_frame,
           conversation_path: path,
           running_ids: running_ids
         })}
      end

      when_ "a coding question arrives and recovery checks run", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Should the export retain its original column names?",
                  options: [%{label: "Retain"}, %{label: "Rename"}]
                }
              ]
            },
            context.coding_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))

        for _ <- 1..2 do
          {:reply, checked, _} = CheckIn.execute(%{}, context.main_frame)
          refute checked.isError, response_text(checked)
        end

        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the question remains visible but autonomous execution stays off", context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        assert response_text(inbox) =~ context.question_id
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.main_id)
        assert HeldProvider.seen() == []
        assert Machine.running() == context.running_ids
        {:ok, context}
      end

      when_ "the user explicitly chats with that same agent", context do
        {:ok, :started} =
          Machine.send_message(
            context.main_id,
            "explicit-user-chat",
            "Please summarize the export question"
          )

        HeldProvider.await_request()
        [request] = HeldProvider.seen()
        assert request =~ "Please summarize the export question"
        HeldProvider.release()
        :ok = Machine.await_idle(context.main_id)
        {:ok, context}
      end

      then_ "chat answers without restoring continuous work", context do
        # `await_idle/1` is the engine's own view: its turn loop has nothing
        # left to run. The transcript is written on the *server*, from what the
        # harness reports back over the channel after that, so reading the page
        # the instant the engine goes quiet reads it before the report lands —
        # "Nothing recorded yet" for a turn that plainly happened. Criterion
        # 2895 asserts the same arrival the same way.
        eventually(fn ->
          {:ok, view, _} = live(context.conn, context.conversation_path)

          assert render(view) =~ HeldProvider.answer(),
                 "the turn finished and its answer is not in the agent's transcript"

          assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        end)

        assert Machine.running() == context.running_ids
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end

      when_ "continuous is deliberately re-enabled with eligible question work still waiting",
            context do
        # The waiting work is the question main is holding, not a graph node.
        # `role_queue_size/2` counts actionable requirements for a role, and
        # this project has never been kicked off — so it reads zero here and
        # would have made the premise false while the eligible work sat in
        # main's inbox the whole time. `Work.question_work?/2` admits a turn on
        # exactly what this listing shows.
        {:reply, waiting, _} = ListNotifications.execute(%{}, context.main_frame)
        refute waiting.isError, response_text(waiting)

        assert response_text(waiting) =~ context.question_id,
               "the premise is eligible work still waiting on main, and the " <>
                 "question it holds is that work"

        HeldProvider.hold()

        {:reply, enabled, _} =
          SetAgentContinuous.execute(
            %{agent_id: context.main_id, continuous: true},
            context.main_frame
          )

        refute enabled.isError, response_text(enabled)
        {:ok, context}
      end

      then_ "one unassigned turn uses the existing agent instead of staffing another", context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.main_id)
        assert Machine.running() == context.running_ids
        {:reply, tasks, _} = ListTasks.execute(%{}, context.main_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
