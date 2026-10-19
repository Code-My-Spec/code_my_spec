defmodule CodeMySpecWeb.WorkingCopyLive.Components.CopyPreviewMarkerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecWeb.WorkingCopyLive.Components.Copy

  defp marker(attrs),
    do: render_component(&Copy.preview_marker/1, harness: struct(WorkingCopy, attrs))

  test "a copy serving on a tunnel links to its preview" do
    html =
      marker(
        app_status: "serving",
        app_url: "http://127.0.0.1:60584",
        preview_url: "https://preview-abc.codemyspec.com"
      )

    assert html =~ ~s(data-state="shared")
    assert html =~ ~s(href="https://preview-abc.codemyspec.com")
    assert html =~ "Serving at preview-abc.codemyspec.com"
  end

  test "the main copy counts as serving from its preview's health" do
    html = marker(preview_status: "serving", preview_url: "https://dev.codemyspec.com")

    assert html =~ ~s(data-state="shared")
  end

  test "a copy serving with no tunnel links to its local address and says so" do
    html = marker(app_status: "serving", app_url: "http://127.0.0.1:60584")

    assert html =~ ~s(data-state="local")
    assert html =~ ~s(href="http://127.0.0.1:60584")
    assert html =~ "Running locally at 127.0.0.1:60584"
  end

  test "a copy with nothing running is grey and links nowhere" do
    html = marker(app_status: "down")

    assert html =~ ~s(data-state="down")
    refute html =~ "href="
    assert html =~ "No app running on this copy"
  end
end
