defmodule CodeMySpecSpex.Story1108.Criterion4652Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4652 — An agent cannot reach another copy's app.

  Rule: An agent on the copy can start, restart and stop its copy's app.

  `EnsureAppRunning`'s schema names no working copy — the caller's own
  comes from the connection's scope, so there is nothing here for an agent
  to point at a different copy with. Proven concretely: a second copy's
  harness is live and connected, the calling scope belongs to a *different*,
  unconnected one, and the tool still resolves to the caller's own copy —
  reported unreachable — rather than reaching the other, connected one.
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Stories.Tools.EnsureAppRunning
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The tool never reaches a copy other than the caller's own" do
    scenario "a second copy is connected; the caller's own is not" do
      given_ "a second working copy, connected to the server", context do
        {:ok, other} =
          WorkingCopies.issue(context.scope, nil, device: device_id(context), root: "/a/second-copy")

        {:ok, _reply, _socket} = join_harness_project(context, other.id)

        {:ok, Map.put(context, :other_copy_id, other.id)}
      end

      when_ "the agent — on its own, unconnected copy — calls the tool", context do
        assert context.scope.active_working_copy_id != context.other_copy_id,
               "the premise requires the caller's own copy to be a different one"

        response = EnsureAppRunning.execute(%{}, frame_for(context.scope))
        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is told its own copy is unreachable — never routed to the connected one", context do
        {:reply, response, _frame} = context.response
        text = response_text(response)

        assert text =~ "not" or text =~ "could not" or text =~ "unreachable" or text =~ "connected",
               "expected a refusal naming the caller's own copy as unreachable, got: #{text}"

        refute text =~ "serving",
               "the tool reported an app serving — it must have reached the other, " <>
                 "connected copy instead of refusing on the caller's own"

        {:ok, context}
      end
    end
  end

  defp join_harness_project(context, working_copy_id) do
    scope = context.scope

    socket(UserSocket, "harness_test", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{scope.active_project_id}", %{
      "label" => "the harness at /workspace/other",
      "harness_id" => working_copy_id,
      "device" => %{"id" => device_id(context)}
    })
  end

  defp frame_for(scope), do: %Anubis.Server.Frame{assigns: %{current_scope: scope}}
end
