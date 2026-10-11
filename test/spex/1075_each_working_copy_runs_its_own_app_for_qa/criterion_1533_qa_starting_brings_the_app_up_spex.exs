defmodule CodeMySpecSpex.Story1108.Criterion4657Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4657 — QA starting brings the app up.

  Rule: A copy's app starts when QA needs it.

  `QaStory.command/2` builds the prompt `start_task` hands a QA agent —
  this asserts that for a non-main copy, that prompt names the copy's own
  address rather than always pointing at main's, and that producing it is
  itself what asks the harness to bring the app up (issue 2d612ae8:
  metric_flow's story 1103 QA session got main's pre-fix code because
  nothing told it to look anywhere else).
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.DeviceHelpers

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Building the QA prompt for a non-main copy asks the harness for its own app",
    criterion: 1533 do
    scenario "a story on a working copy that is not main" do
      given_ "a story, and this copy's harness connected", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Some feature",
            description: "A feature this working copy is implementing.",
            ready_for_dev: false
          )

        {story, task_id, session} = Fixtures.qa_story_task_fixture(context.scope, story: story)
        task = Enum.find(session.tasks, &(&1.id == task_id))
        {:ok, _reply, socket} = join_harness_project(context)

        {:ok,
         context |> Map.put(:story, story) |> Map.put(:task, task) |> Map.put(:socket, socket)}
      end

      when_ "start_task builds the QA prompt for this story", context do
        command_task = Task.async(fn -> QaStory.command(context.scope, context.task) end)

        {:ok, Map.put(context, :command_task, command_task)}
      end

      then_ "the harness was asked to ensure its own app is running", context do
        assert_push("ensure_app_running", %{"ref" => ref})

        reply(context.socket, "ensure_app_running_result", %{
          "ref" => ref,
          "status" => "ok",
          "app_status" => "serving",
          "app_url" => "http://127.0.0.1:56002",
          "app_commit" => "1108c0de"
        })

        assert {:ok, prompt} = Task.await(context.command_task)

        assert prompt =~ "56002"
        assert prompt =~ "1108c0de"

        assert prompt =~ "not main's",
               "the prompt should say plainly that this is the copy's own app, not main's"

        {:ok, context}
      end
    end
  end

  defp join_harness_project(context) do
    scope = context.scope

    socket(UserSocket, "harness_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{scope.active_project_id}", %{
      "label" => "the harness at /workspace/app",
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => device_id(context)}
    })
  end

  defp reply(socket, event, payload) do
    ref = Phoenix.ChannelTest.push(socket, event, payload)

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok} -> :ok
    after
      1_000 -> flunk("#{event} was never acknowledged")
    end
  end
end
