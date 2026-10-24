defmodule CodeMySpecSpex.Story1138.Criterion2337Spex do
  @moduledoc """
  Story 1138 — A dev box says whether it is up.
  Criterion 2337 — A box whose harness dropped is down.

  Disconnecting is driven through the real channel leaving, not a direct
  call to a `terminate/2` callback: the channel is a real linked process,
  and only actually stopping it fires whatever releases its
  `HarnessRegistry` registration. Trapping exits and waiting for the
  channel process's own `:DOWN` is the same shape
  `harness_project_channel_test.exs`'s "the channel's lifetime is the
  lease" describe block uses, so the disconnect this spec drives is
  genuinely finished, not merely requested, before the Dev boxes page is
  read.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers
  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.ChannelTest

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    Process.flag(:trap_exit, true)
    :ok
  end

  spex "A dev box is up exactly when its harness is connected", criterion: 2337 do
    scenario "A box whose harness dropped is down" do
      given_ "'cloud-1''s session paused and its harness disconnected", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        device_id = box_device_id(live, "cloud-1")

        {_reply, socket} =
          join_working_copy_socket(context, "/srv/cloud-1/app", "cloud-1", device_id: device_id)

        down_ref = Process.monitor(socket.channel_pid)
        leave(socket)
        assert_receive {:DOWN, ^down_ref, :process, _, _}, 2_000

        {:ok, Map.put(context, :device_id, device_id)}
      end

      when_ "Sam opens Dev boxes", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :live, live)}
      end

      then_ "'cloud-1' is down", context do
        selector =
          "[data-test='device'][data-device-id='#{context.device_id}'] [data-test='dev-box-up']"

        assert has_element?(context.live, selector),
               "the Dev boxes page has no up/down indicator for 'cloud-1' at all"

        text =
          context.live
          |> element(selector)
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert text =~ ~r/\bdown\b/i,
               "'cloud-1''s harness disconnected but the Dev boxes page does not show it as " <>
                 "down:\n\n#{text}"

        # Not a bare `~r/\bup\b/i` refutation: the down state's own "Last up
        # HH:MM" text legitimately contains the word "up", so only the
        # leading status word is checked here.
        refute String.trim(text) =~ ~r/^up\b/i,
               "'cloud-1''s harness disconnected but the Dev boxes page still shows it as " <>
                 "up:\n\n#{text}"

        {:ok, context}
      end
    end
  end
end
