defmodule CodeMySpecWeb.PreviewAddressBarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpecWeb.PreviewComponents

  @src "https://preview-abc.codemyspec.com"

  defp render_pane(assigns) do
    (&PreviewComponents.pane/1)
    |> render_component(assigns)
    |> Floki.parse_document!()
  end

  defp attr(doc, selector, name), do: doc |> Floki.find(selector) |> Floki.attribute(name)

  test "a running pane with an address shows that address above the frame" do
    doc = render_pane(state: :running, src: @src)

    assert attr(doc, "[data-test='preview-url']", "value") == [@src]
    assert attr(doc, "[data-test='preview-url']", "readonly") != []
    assert attr(doc, "[data-test='preview-copy']", "phx-hook") == ["Copy"]
    assert attr(doc, "[data-test='preview-copy']", "data-to") == ["#preview-url"]
    assert attr(doc, "[data-test='preview-open']", "href") == [@src]
    assert attr(doc, "[data-test='preview-open']", "target") == ["_blank"]
    assert attr(doc, "[data-test='preview-open']", "rel") == ["noopener noreferrer"]
    assert attr(doc, "[data-test='preview-frame']", "src") == [@src]
  end

  test "the bar takes the frame's width" do
    doc = render_pane(state: :running, src: @src, viewport: "phone")

    [class] = attr(doc, "[data-test='preview-address']", "class")
    assert class =~ "w-[390px]"
  end

  for state <- [:absent, :starting, :down, :broken] do
    test "no address bar when #{state}" do
      doc = render_pane(state: unquote(state), src: @src)

      assert Floki.find(doc, "[data-test='preview-address']") == []
    end
  end

  test "no address bar when running without an address" do
    doc = render_pane(state: :running, src: nil)

    assert Floki.find(doc, "[data-test='preview-address']") == []
  end
end
