defmodule CodeMySpecSpex.DeviceSyncHelpers do
  @moduledoc "Real destination checkout and harness channel for remote publication acceptance tests."
  import ExUnit.Assertions
  import Phoenix.ChannelTest
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PromotionHelpers, as: Promotion
  alias CodeMySpecSpex.RemotePromotionHelpers, as: Remote

  def offline_destination(context) do
    root = Path.join(Path.dirname(context.origin), "desktop")
    Remote.git!(Path.dirname(context.origin), ["clone", context.origin, root])
    device = Fixtures.device_fixture(context.scope)

    {copy, socket} =
      Promotion.join_main_working_copy_socket(context, root, "desktop preview",
        device_id: device.id
      )

    Process.unlink(socket.channel_pid)
    close(socket)
    Map.merge(context, %{destination_root: root, destination: copy, destination_device: device})
  end

  def reconnect(context) do
    before = CodeMySpec.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()

    {_, socket} =
      Promotion.join_local_working_copy_socket(
        context,
        context.destination_root,
        "desktop preview",
        device_id: context.destination_device.id,
        working_copy_id: context.destination.working_copy_id,
        app_verbs: ["reload_app"]
      )

    Map.merge(context, %{destination_socket: socket, sync_tasks_before: before})
  end

  def serve_revision(context) do
    socket = context.destination_socket
    answer_app(socket, "ensure_app_running", context.base)

    answer_app(
      socket,
      ["reload_app", "restart_app"],
      Remote.git!(context.destination_root, ["rev-parse", "HEAD"])
    )

    context
  end

  defp answer_app(socket, verbs, head) do
    join_ref = socket.join_ref
    verbs = List.wrap(verbs)

    receive do
      %Phoenix.Socket.Message{join_ref: ^join_ref, event: verb, payload: %{"ref" => ref}}
      when verb in ["ensure_app_running", "reload_app", "restart_app"] ->
        assert verb in verbs, "unexpected destination request #{verb}"

        reply =
          push(socket, verb <> "_result", %{
            "ref" => ref,
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:47400",
            "app_commit" => head,
            "app_serving_commit" => head,
            "app_head" => head
          })

        assert_reply(reply, :ok, _, 5_000)
    after
      10_000 -> flunk("destination never received #{inspect(verbs)}")
    end
  end

  def dirty_destination(context) do
    Promotion.write(context.destination_root, "lib/example.ex", "Uncommitted work must survive\n")
    context
  end

  def copies(context) do
    {:ok, text} = ToolLibrary.run("list_working_copies", %{}, %{scope: context.scope})
    text
  end

  # The status is written by the sync task the reconnect started; a polling
  # budget ran out on a loaded gate before the task did. Wait for the task.
  def await_status(context, status) do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> MapSet.new()
    |> MapSet.difference(context.sync_tasks_before)
    |> Enum.each(&await_down/1)

    text = copies(context)
    assert text =~ "device sync #{status}"
    text
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      30_000 -> flunk("device sync task #{inspect(pid)} still running after 30s")
    end
  end
end
