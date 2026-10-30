defmodule CmsHarness.RecordsOnlyChangeReportsTheOverlayWithoutARescanTest do
  @moduledoc """
  A refreshed read model whose only change is the records the overlay reads
  (a criterion added, a story numbered) re-reports the overlay from the last
  scan. The disk did not change, so it is not rescanned; a change scanning
  reads still is.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.Sync

  @observations [%{path: "lib/a.ex", role: :implementation}]

  setup do
    owner = self()
    :meck.new(Sync, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Sync) end)
    :meck.expect(Sync, :start, fn _project, model -> send(owner, {:rescan, model}) && :ok end)

    :meck.expect(Sync, :start_overlay, fn _project, observations, model ->
      send(owner, {:overlay_only, observations, model}) && :ok
    end)

    :ok
  end

  test "new records alone re-report the overlay from the last scan" do
    refreshed(payload(%{"authored" => true}), payload(%{"authored" => false}))

    assert_receive {:overlay_only, @observations, %{overlay_records: %{"authored" => false}}}
    refute_received {:rescan, _}
  end

  test "a change scanning reads is rescanned" do
    refreshed(payload(%{}), Map.put(payload(%{}), "strict", false))

    assert_receive {:rescan, %{strict?: false}}
    refute_received {:overlay_only, _, _}
  end

  defp refreshed(before, now) do
    ref = make_ref()
    {:ok, _socket} = ChannelClient.handle_reply(ref, {:ok, before}, socket(ref, :join, nil))
    assert_receive {:rescan, previous}

    ChannelClient.handle_reply(ref, {:ok, now}, socket(ref, :refresh, previous))
  end

  defp socket(ref, reason, previous) do
    %Slipstream.Socket{
      assigns: %{
        read_model_ref: ref,
        read_model_reason: reason,
        read_model: previous,
        project: %{root: "/nowhere"},
        last_observations: @observations
      }
    }
  end

  defp payload(records) do
    %{"overlay_records" => records, "fingerprint" => inspect(records), "strict" => true}
  end
end
