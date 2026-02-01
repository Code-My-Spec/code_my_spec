defmodule CodeMySpec.Documents.Parsers.SurfaceComponentParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Documents.Parsers.SurfaceComponentParser

  defp parse_markdown(markdown) do
    {:ok, ast, _} = Earmark.Parser.as_ast(markdown)
    # Strip the H2 header to get just the surface component content
    ast
    |> Enum.drop_while(fn
      {"h2", _, _, _} -> true
      _ -> false
    end)
    |> SurfaceComponentParser.from_ast()
  end

  describe "from_ast/1" do
    test "parses surface component with list-style fields" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.DashboardLive

      - **Type:** liveview
      - **Description:** Main dashboard view
      - **Stories:** 1, 2
      """

      [component] = parse_markdown(markdown)

      assert component.name == "MetricFlowWeb.DashboardLive"
      assert component.type == "liveview"
      assert component.description == "Main dashboard view"
      assert component.story_ids == [1, 2]
    end

    test "parses surface component with paragraph-style description" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.AgencyLive
      Agency management interface for admins.

      **Type:** liveview

      **Stories:** 427
      """

      [component] = parse_markdown(markdown)

      assert component.name == "MetricFlowWeb.AgencyLive"
      assert component.description == "Agency management interface for admins."
      assert component.type == "liveview"
      assert component.story_ids == [427]
    end

    test "defaults type to 'live' when not specified" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.HomeLive
      Home page.

      **Stories:** 1
      """

      [component] = parse_markdown(markdown)

      assert component.type == "liveview"
    end

    test "parses multiple surface components" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.DashboardLive
      Dashboard view.

      **Type:** liveview

      **Stories:** 1

      ---

      ### MetricFlowWeb.SettingsLive
      Settings page.

      **Type:** liveview

      **Stories:** 2
      """

      components = parse_markdown(markdown)

      assert length(components) == 2
      assert Enum.any?(components, &(&1.name == "MetricFlowWeb.DashboardLive"))
      assert Enum.any?(components, &(&1.name == "MetricFlowWeb.SettingsLive"))
    end

    test "handles component without description" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.HealthController

      **Type:** controller

      **Stories:** 1
      """

      [component] = parse_markdown(markdown)

      assert component.name == "MetricFlowWeb.HealthController"
      assert component.type == "controller"
      assert component.description == nil
    end

    test "prefers explicit **Description:** over paragraph" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.TestLive
      This paragraph should be ignored.

      - **Description:** This is the real description
      - **Type:** liveview
      - **Stories:** 1
      """

      [component] = parse_markdown(markdown)

      # Should use the explicit **Description:** field
      assert component.description == "This is the real description"
    end

    test "handles nested LiveView names" do
      markdown = """
      ## Surface Components

      ### MetricFlowWeb.DashboardLive.Index
      Dashboard index page.

      **Type:** liveview

      **Stories:** 1
      """

      [component] = parse_markdown(markdown)

      assert component.name == "MetricFlowWeb.DashboardLive.Index"
      assert component.description == "Dashboard index page."
    end
  end
end
