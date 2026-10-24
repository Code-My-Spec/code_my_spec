defmodule CodeMySpecSpex.Story1134.Criterion2324Spex do
  @moduledoc """
  Story 1134 — A dev box's harness starts with its session.
  Criterion 2324 — No second box after a recycle.

  There is no Claude Code cloud VM to pause in a spec. What Sam is given is the
  setup script the environment runs, which installs the SessionStart hook that
  brings the harness up, so this reads the script the Dev boxes page showed him
  (the same surface story 1133 reads) and drives the server half for real: the
  box signing in again, and the channel join.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  import CodeMySpecSpex.WorkingCopyHelpers,
    only: [join_working_copy: 4, join_working_copy_socket: 4]

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A recycled box is the same box with the same copy", criterion: 2324 do
    scenario "the harness reconnects after a recycle" do
      given_ "Sam's box 'cloud-1' was recycled", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        box = add_box(live, "cloud-1", "claude_code_cloud")
        _ = exchanged(box.token)

        {first, socket} =
          join_working_copy_socket(context, "/workspace/app", "cloud-1", device_id: box.id)

        {:ok, Map.merge(context, %{live: live, box: box, first: first, socket: socket})}
      end

      when_ "its harness reconnects", context do
        destroy_container(context.socket)
        again = exchanged(context.box.token)

        rejoined =
          join_working_copy(context, "/workspace/app", "cloud-1",
            device_id: context.box.id,
            working_copy_id: context.first["working_copy_id"]
          )

        {:ok, Map.merge(context, %{again: again, rejoined: rejoined})}
      end

      then_ "it is still 'cloud-1' with the same working copy", context do
        assert context.again["device_id"] == context.box.id
        assert context.rejoined["working_copy_id"] == context.first["working_copy_id"]
        {:ok, context}
      end

      then_ "no new box or copy appears", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)

        assert live |> render() |> String.split("data-box-name=") |> length() == 2,
               "a second box appeared"

        {:ok, context}
      end
    end
  end

  # The container going away, from the server's side: the connection drops and
  # the lease it held is free. Unlinked first because the test process is linked
  # to the channel and would otherwise exit with it.
  defp destroy_container(socket) do
    pid = socket.channel_pid
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Phoenix.ChannelTest.leave(socket)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    :ok
  end
end
