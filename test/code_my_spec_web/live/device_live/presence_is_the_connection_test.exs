defmodule CodeMySpecWeb.DeviceLive.PresenceIsTheConnectionTest do
  @moduledoc """
  A connected machine reads Present however long ago it last did anything.

  Issue 5b5c33ec, which had to be fixed twice. The first fix cascaded
  `mark_alive` from a working copy to its machine, and that still went stale:
  `last_seen_at` is written when something *happens*, so a box that is up and
  simply not changing files aged out anyway. Observed live, "Last seen 4m ago"
  against a `/health` reporting `connected: true` with a four-second-old reply.

  ## Why criterion 2849's spex did not catch either version

  It joins a working copy and reads the row immediately. At t=0 the timestamp is
  fresh, so the old threshold — under two minutes means Present — passes just as
  well as reading the connection does. The bug was entirely about time passing,
  and the spex never lets any pass.

  So this is the case that separates them: a live connection with a stale
  timestamp. On a threshold it reads "Last seen"; on the connection it reads
  Present. Nothing else in the suite makes that distinction, which is how the
  same defect shipped twice.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp row_for(conn, device_id) do
    {:ok, live, _html} = live(conn, "/app/devices")

    live
    |> element("[data-test='device'][data-device-id='#{device_id}']")
    |> render()
  end

  defp backdate(device_id, seconds) do
    Repo.get!(Device, device_id)
    |> Ecto.Changeset.change(
      last_seen_at: DateTime.add(DateTime.utc_now(), -seconds, :second)
    )
    |> Repo.update!()
  end

  test "a live connection reads Present with an hour-old timestamp", context do
    id = device_id(context, hostname: "a-quiet-live-machine", kind: "local")
    join_working_copy(context, "/tmp/presence-live", "a quiet checkout", device_id: id)

    backdate(id, 3600)

    row = row_for(context.conn, id)

    assert row =~ ~r/present|online|connected/i,
           "a machine with a live connection read as stale because its timestamp was " <>
             "old. That is the whole defect: last_seen_at records when something " <>
             "happened, and a box that is up and quiet has nothing happening on it. " <>
             "Got: #{row}"
  end

  test "no connection reads Last seen, however recent the timestamp", context do
    id = device_id(context, hostname: "a-departed-machine", kind: "local")

    # No join at all — the machine announced itself once and went away. Recent
    # timestamp, no connection, and the honest answer is the fallback.
    backdate(id, 5)

    row = row_for(context.conn, id)

    refute row =~ ~r/\bpresent\b/i,
           "an unreachable machine read as present on the strength of a fresh " <>
             "timestamp. Separating a quiet box from a departed one is the only " <>
             "reason this column exists, and a timestamp cannot do it in either " <>
             "direction. Got: #{row}"
  end
end
