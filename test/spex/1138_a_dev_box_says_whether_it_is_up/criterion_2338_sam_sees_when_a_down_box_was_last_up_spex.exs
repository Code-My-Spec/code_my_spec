defmodule CodeMySpecSpex.Story1138.Criterion2338Spex do
  @moduledoc """
  Story 1138 — A dev box says whether it is up.
  Criterion 2338 — Sam sees when a down box was last up.

  The criterion's own example names a clock time ("14:02"); a spex cannot
  make real wall-clock time land on a chosen minute, so this captures the
  real moment the harness actually disconnects (right after the real
  channel leave that criterion 2337 also drives) and checks the page's
  "last up" reading against that moment's own `HH:MM`, in UTC -- this
  process's own clock, since nothing in this server-rendered page defers
  to a browser timezone. That is the same claim the criterion makes,
  proven against a time this run actually produced rather than one it
  could not reliably produce.
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

  spex "Dev boxes shows each box as up or down, and when it was last up", criterion: 2338 do
    scenario "Sam sees when a down box was last up" do
      given_ "'cloud-1' went down", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        device_id = box_device_id(live, "cloud-1")

        {_reply, socket} =
          join_working_copy_socket(context, "/srv/cloud-1/app", "cloud-1", device_id: device_id)

        down_ref = Process.monitor(socket.channel_pid)
        leave(socket)
        assert_receive {:DOWN, ^down_ref, :process, _, _}, 2_000

        {:ok, Map.merge(context, %{device_id: device_id, went_down_at: DateTime.utc_now()})}
      end

      when_ "Sam opens Dev boxes", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        {:ok, Map.put(context, :live, live)}
      end

      then_ "it shows down, last up at the time it went down", context do
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
               "'cloud-1' went down but the Dev boxes page does not show it as down:\n\n#{text}"

        expected = Calendar.strftime(context.went_down_at, "%H:%M")

        assert text =~ expected,
               "the Dev boxes page does not show when 'cloud-1' was last up (expected " <>
                 "#{expected}):\n\n#{text}"

        {:ok, context}
      end
    end
  end
end
