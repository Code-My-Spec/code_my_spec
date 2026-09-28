defmodule CodeMySpecSpex.Story1108.Criterion4662Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4662 — A stopped copy says so.

  Rule: A copy with no running app says so, and never serves main's code.

  Driven at the server's own channel, the way a real harness's `_result`
  push arrives — `HarnessProjectChannel.handle_in/3` is what calls
  `WorkingCopies.record_app_status/2`, and this asserts against the
  persisted row a page reading this copy's status actually sees, not just
  the reply a caller gets back. `app_url` clearing on "down" is the exact
  failure this story exists to prevent (issue 2d612ae8: a stale address
  read as though it were live).
  """

  use CodeMySpecSpex.Case

  import Phoenix.ChannelTest
  import CodeMySpecSpex.DeviceHelpers

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Stopping the app clears its address, not just its status", criterion: 1538 do
    scenario "a copy that was serving, then stopped" do
      given_ "a working copy joined to its server channel", context do
        {:ok, _reply, socket} = join_harness_project(context)
        {:ok, Map.put(context, :socket, socket)}
      end

      given_ "the copy already reported serving", context do
        # Phoenix.ChannelTest.push is the drive: a push over the joined
        # channel is what makes the server call
        # WorkingCopies.record_app_status/2, the same as a real harness's
        # `_result` would.
        ref =
          Phoenix.ChannelTest.push(context.socket, "ensure_app_running_result", %{
            "ref" => "unwaited",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:51234",
            "app_commit" => "abc1234"
          })

        await_ok(ref)

        {:ok, copy} = WorkingCopies.fetch(context.scope.active_working_copy_id)
        assert copy.app_status == "serving"
        assert copy.app_url == "http://127.0.0.1:51234"

        {:ok, context}
      end

      when_ "the harness reports the app stopped", context do
        report(context.socket, "stop_app_result", %{"status" => "ok"})
        {:ok, context}
      end

      then_ "the copy's row says down, with no address left standing", context do
        {:ok, copy} = WorkingCopies.fetch(context.scope.active_working_copy_id)

        assert copy.app_status == "down"

        assert copy.app_url == nil,
               "a stale address on a stopped copy is exactly what this story exists to prevent"

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

  # A ref no `AppTransport` call is waiting on — `handle_in` still decodes
  # and persists the report, the same as it would for one tied to a parked
  # caller. Only the `GenServer.reply/2` half (nothing to reply to here) is
  # skipped.
  defp report(socket, event, payload) do
    ref = Phoenix.ChannelTest.push(socket, event, Map.put(payload, "ref", "unwaited"))
    await_ok(ref)
  end

  defp await_ok(ref) do
    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok} -> :ok
    after
      1_000 -> flunk("push #{ref} was never acknowledged")
    end
  end
end
