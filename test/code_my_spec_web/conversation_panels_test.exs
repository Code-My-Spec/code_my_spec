defmodule CodeMySpecWeb.ConversationPanelsTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpecWeb.ConversationPanels

  @base_assigns %{
    screen: :narrow,
    open: [:preview],
    dynamic_view: "epics",
    dynamic_stories: [],
    dynamic_story: nil,
    dynamic_epics: [],
    offer: nil,
    waiting: [],
    copies: [],
    project_id: "project-1",
    conversation_id: nil,
    preview_src: "https://preview-project-1.codemyspec.com"
  }

  describe "panels/1, preview tab" do
    test "shows the project's own extra origins beside the frame" do
      html =
        render_component(
          &ConversationPanels.panels/1,
          Map.put(@base_assigns, :extra_frame_origins, ["accounts.google.com", "gitlab.com"])
        )

      assert html =~ "panel-preview-extra-origins"
      assert html =~ "accounts.google.com, gitlab.com"
    end

    test "says nothing when there are no extra origins to show" do
      html =
        render_component(
          &ConversationPanels.panels/1,
          Map.put(@base_assigns, :extra_frame_origins, [])
        )

      refute html =~ "panel-preview-extra-origins"
    end
  end
end
