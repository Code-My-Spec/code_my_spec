defmodule CodeMySpecSpex.Story1047.Criterion3563Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3563 — An active task blocks another turn.

  Claim through start_task, then request eligibility reconsideration through
  the main agent's tool. No turn is in flight: the active durable task itself
  must prevent admission until the agent explicitly dispositions it.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import Phoenix.ChannelTest

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An active task prevents another work turn", criterion: 1461 do
    scenario "Continuous intent cannot bypass an undispositioned task" do
      given_ "an idle continuous QA agent owns an active QA task", context do
        context = given_a_staffed_checkout(context, "spex_3563")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) > 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        # `qa_complete`'s prompt resolves this checkout's own app via a live
        # `ensure_app_running` dispatch (story 1108/1003 — main is just
        # another working copy now, so it is no longer skipped). This
        # criterion is about task concurrency, not app-serving, so the
        # answer only needs to unblock the prompt build, not be meaningful.
        claim_task =
          Task.async(fn ->
            ToolLibrary.run(
              "start_task",
              %{
                requirement_name: "qa_complete",
                entity_type: "story",
                entity_id: to_string(context.story.number)
              },
              Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
            )
          end)

        assert_push "ensure_app_running", %{"ref" => ref}, 5_000

        reply_ref =
          Phoenix.ChannelTest.push(context.harness_socket, "ensure_app_running_result", %{
            "ref" => ref,
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:4000",
            "app_commit" => "cafef00d"
          })

        receive do
          %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
        after
          1_000 -> flunk("ensure_app_running_result was never acknowledged")
        end

        claim = Task.await(claim_task, 5_000)

        assert match?({:ok, _}, claim), response_text(claim)

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "**qa_complete**"
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: agent.id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           tasks_before: response_text(tasks),
           conversation_before: response_text(conversation),
           history_before: Machine.history(agent.id)
         })}
      end

      when_ "the main agent reaffirms continuous work", context do
        response =
          ToolLibrary.run(
            "set_agent_continuous",
            %{agent_id: context.agent_id, continuous: true},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)
        {:ok, context}
      end

      then_ "no work turn starts and the original task remains active", context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert HeldProvider.seen() == []

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, context}
      end
    end
  end
end
