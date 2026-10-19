defmodule CodeMySpecWeb.WorkingCopyLive.Components.CopyHarnessMarkerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpecWeb.WorkingCopyLive.Components.Copy

  defp marker(row, size \\ :small),
    do: render_component(&Copy.harness_marker/1, row: row, size: size)

  test "an attached copy is a faint mark naming its machine, and says nothing aloud at normal size" do
    row = %{served: true, device_name: "Johns-Mac-mini"}

    assert marker(row) =~ ~s(data-state="attached")
    assert marker(row) =~ "Held by the harness on Johns-Mac-mini"
    refute marker(row, :normal) =~ "No harness attached"
    assert marker(row, :normal) =~ ~s(data-test="copy-ready")
  end

  test "an unattached copy is amber when small and says why at normal size" do
    row = %{served: false, device_name: "Johns-Mac-mini"}

    assert marker(row) =~ ~s(data-state="unattached")
    assert marker(row) =~ "its agents cannot run"
    assert marker(row, :normal) =~ "No harness attached"
    assert marker(row, :normal) =~ ~s(data-test="copy-not-ready")
  end
end
