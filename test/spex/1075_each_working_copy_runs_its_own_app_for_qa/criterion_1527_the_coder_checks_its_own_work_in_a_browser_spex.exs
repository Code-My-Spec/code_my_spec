defmodule CodeMySpecSpex.Story1108.Criterion4651Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4651 — The coder checks its own work in a browser.

  Rule: An agent on the copy can start, restart and stop its copy's app.

  Driven through the actual MCP tool a coding agent calls
  (`EnsureAppRunning`), against a real `HarnessProjectChannel` join — the
  same round trip the channel-level spex use, reached this time the way an
  agent reaches it: through `AppTransport`, resolved from the caller's own
  scope. See criterion 4652 for the other half of this rule (an agent
  cannot reach another copy's app).
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Stories.Tools.EnsureAppRunning
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The tool reaches the caller's own copy and reports it serving", criterion: 1527 do
    scenario "an agent on a copy whose harness is connected" do
      given_ "the agent's own working copy joined to the server", context do
        {:ok, _reply, socket} = join_harness_project(context)
        {:ok, Map.put(context, :socket, socket)}
      end

      when_ "the coding agent calls its own start/ensure tool", context do
        task = Task.async(fn -> EnsureAppRunning.execute(%{}, frame_for(context.scope)) end)
        {:ok, Map.put(context, :task, task)}
      end

      then_ "the harness is asked, and answers serving", context do
        assert_push "ensure_app_running", %{"ref" => ref}

        reply(context.socket, "ensure_app_running_result", %{
          "ref" => ref,
          "status" => "ok",
          "app_status" => "serving",
          "app_url" => "http://127.0.0.1:55001",
          "app_commit" => "cafefeed"
        })

        {:reply, response, _frame} = Task.await(context.task)
        text = response_text(response)

        assert text =~ "55001"
        assert text =~ "cafefeed"

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

  defp frame_for(scope), do: %Anubis.Server.Frame{assigns: %{current_scope: scope}}

  defp reply(socket, event, payload) do
    ref = Phoenix.ChannelTest.push(socket, event, payload)

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok} -> :ok
    after
      1_000 -> flunk("#{event} was never acknowledged")
    end
  end
end
