defmodule CodeMySpec.McpServers.CodeModeTest do
  @moduledoc """
  The MCP half of code mode, against the server's real registrations.

  `CodeModeTest` covers the runtime with two fake tools. This covers what fakes
  cannot: that the catalog built from 111 real registrations actually binds,
  that a real tool runs under the caller's scope, and that the two code-mode
  tools are not in their own catalog.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.CodeMode, as: Layer
  alias CodeMySpec.McpServers.CodeMode.Tools.{RunScript, ToolDocs}
  alias CodeMySpec.McpServers.LocalServer

  defp text(response) do
    response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")
  end

  describe "the catalog built from the real server" do
    test "binds most of the server's tools" do
      catalog = Layer.catalog(full_scope_fixture())

      assert map_size(catalog) > 90,
             "the catalog should be nearly every registered tool, got #{map_size(catalog)}"

      assert Map.has_key?(catalog, "list_stories")
      assert Map.has_key?(catalog, "get_story")
    end

    test "and leaves out the ones a script must not call" do
      catalog = Layer.catalog(full_scope_fixture())

      refute Map.has_key?(catalog, "ask_user"),
             "a loop over ask_user is questions nobody agreed to"

      refute Map.has_key?(catalog, "start_agent"), "a loop over start_agent is a fleet"

      refute Map.has_key?(catalog, "run_script"), """
      A script could call run_script, and that one could call it again — each
      nesting a fresh VM inside a tool call of the last. The limits are
      per-evaluation and would not see it.
      """

      refute Map.has_key?(catalog, "tool_docs")
    end

    test "every excluded name is a tool that really exists" do
      # Otherwise a rename silently un-excludes something: the name stops
      # matching, the tool comes back, and nothing says so.
      registered = MapSet.new(LocalServer.__components__(), & &1.name)

      missing = Enum.reject(Catalog.excluded(), &MapSet.member?(registered, &1))

      assert missing == [],
             "these are excluded but no longer registered, so the exclusion is dead: " <>
               inspect(missing)
    end
  end

  describe "run_script against real tools" do
    setup do
      scope = full_scope_fixture()
      %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
    end

    test "a real tool runs and its output comes back", %{scope: scope, frame: frame} do
      story_fixture(scope, %{title: "A story code mode can see"})

      assert {:reply, response, ^frame} =
               RunScript.execute(%{script: ~S[return list_story_titles()]}, frame)

      assert response.isError == false
      assert text(response) =~ "A story code mode can see"
    end

    test "several tools in one call", %{scope: scope, frame: frame} do
      story_fixture(scope, %{title: "First"})
      story_fixture(scope, %{title: "Second"})

      script = ~S"""
      print("listing")
      local titles = list_story_titles()
      print("listed")
      return titles
      """

      assert {:reply, response, ^frame} = RunScript.execute(%{script: script}, frame)

      body = text(response)
      assert body =~ "listing"
      assert body =~ "listed"
      assert body =~ "First"
    end

    test "a converted tool answers with records, so a script can compose", %{
      scope: scope,
      frame: frame
    } do
      for title <- ["Alpha", "Beta", "Gamma"] do
        CodeMySpec.StoriesFixtures.story_fixture(scope, %{title: title})
      end

      # The shape that motivated code mode, and the one that did not work while
      # every tool answered with prose: iterate the result, filter it, count.
      script = ~S"""
      local matching = 0
      for _, story in ipairs(list_story_titles()) do
        if string.sub(story.title, 1, 1) == "A" then matching = matching + 1 end
      end
      return matching
      """

      assert {:reply, response, ^frame} = RunScript.execute(%{script: script}, frame)

      refute response.isError

      # Exactly the count, not merely a digit somewhere in the output: three
      # stories exist and one starts with A, so a weak match would pass on the
      # total and prove nothing.
      returned = text(response) |> String.split("Returned:") |> List.last() |> String.trim()

      assert returned in ["1", "1.0"],
             "expected the filtered count, got #{inspect(returned)} — a formatted " <>
               "listing is a string; only records can be iterated, and that is the " <>
               "whole reason script_result/2 exists"
    end

    test "a tool that refuses gives the script an error to handle", %{frame: frame} do
      script = ~S"""
      local story, err = get_story({ story_id = "00000000-0000-0000-0000-000000000000" })
      if story == nil then return "handled: " .. err.message end
      return "unexpectedly found it"
      """

      assert {:reply, response, ^frame} = RunScript.execute(%{script: script}, frame)

      assert response.isError == false
      assert text(response) =~ "handled:"
    end

    test "a script cannot reach a tool it is not given", %{frame: frame} do
      assert {:reply, response, ^frame} =
               RunScript.execute(%{script: ~S[return ask_user({ question = "hi" })]}, frame)

      assert response.isError == true
    end

    test "a caller with no project is refused before anything runs" do
      frame = %Frame{assigns: %{current_scope: user_scope_fixture()}}

      assert {:reply, response, ^frame} = RunScript.execute(%{script: ~S[return 1]}, frame)
      assert response.isError == true
    end
  end

  describe "tool_docs against real tools" do
    setup do
      %{frame: %Frame{assigns: %{current_scope: full_scope_fixture()}}}
    end

    test "the index lists the real tools without their schemas", %{frame: frame} do
      assert {:reply, response, ^frame} = ToolDocs.execute(%{}, frame)

      body = text(response)
      assert body =~ "list_stories"
      assert body =~ "get_story"
    end

    test "and the index is far smaller than the tool list it replaces", %{frame: frame} do
      # The number this story exists to change: 85,979 bytes of tools/list,
      # measured against the running harness on 2026-08-28.
      assert {:reply, response, ^frame} = ToolDocs.execute(%{}, frame)

      assert byte_size(text(response)) < 20_000,
             "an index that costs as much as the schemas it replaces buys nothing"
    end

    test "one tool by name gives its arguments", %{frame: frame} do
      assert {:reply, response, ^frame} = ToolDocs.execute(%{name: "get_story"}, frame)

      body = text(response)
      assert body =~ "# get_story"
      assert body =~ "story_id"
    end

    test "search finds a tool by what it does", %{frame: frame} do
      assert {:reply, response, ^frame} = ToolDocs.execute(%{search: "epic"}, frame)
      assert text(response) =~ "epic"
    end
  end
end
