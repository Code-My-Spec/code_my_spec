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

  describe "the browser's sandbox" do
    setup do
      scope = full_scope_fixture()
      {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
      :ok = CodeMySpec.WorkingCopies.record_machine_tools(copy, ~w(browser_navigate browser_wait))

      %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
    end

    test "is not the one run_script runs in", %{scope: scope} do
      catalog = Layer.catalog(scope)

      refute Map.has_key?(catalog, "browser_navigate"), """
      A browser tool is in `run_script`'s catalog, so the two share a wall
      clock again. They cannot: `browser_wait_for_text` waits for a duration
      the caller passes and `list_stories` is a database read, and the number
      that suits one starves the other.
      """

      assert Map.has_key?(Layer.machine_catalog(scope, nil, 60_000), "browser_navigate")
    end

    test "and reaches nothing of ours", %{scope: scope} do
      catalog = Layer.machine_catalog(scope, nil, 60_000)

      assert Map.keys(catalog) |> Enum.sort() == ~w(browser_navigate browser_wait)

      refute Map.has_key?(catalog, "list_stories"),
             "a script here can reach the project's tools, so nothing was actually " <>
               "separated and the deadline is wrong for half of what it can call"
    end

    test "gives each call less than the script has, so a hang reports as one", %{scope: scope} do
      # The bug the split exists to end, asserted as arithmetic rather than as
      # a story: the inner call used to get a hardcoded 30s inside a script
      # whose own limit was also 30s. They expired together, so the sandbox's
      # brutal kill could take the timeout's own error with it and the caller
      # was left unable to tell which of the two had fired.
      for budget <- [5_000, 60_000, 300_000] do
        %{timeout: given} = Layer.machine_catalog(scope, nil, budget)["browser_navigate"]

        assert given < budget,
               "the call got #{given}ms of a #{budget}ms script, so both clocks " <>
                 "expire at once and neither answer survives the other"
      end
    end

    test "a floor, because a script with almost no budget still gets a real call", %{scope: scope} do
      %{timeout: given} = Layer.machine_catalog(scope, nil, 1_000)["browser_navigate"]

      assert given >= 1_000,
             "a call given #{given}ms cannot reach a browser at all — subtracting the " <>
               "margin from a small budget must not leave a number below what a real " <>
               "call takes"
    end

    test "tool_docs still names them, and says where they are called from", %{frame: frame} do
      assert {:reply, response, ^frame} = ToolDocs.execute(%{}, frame)

      body = text(response)

      assert body =~ "browser_navigate", """
      The browser's tools are out of `run_script`'s catalog and out of the
      index, so an agent has no way left to learn that they exist. Cheaper is
      not the same as smaller.
      """

      assert body =~ "run_browser_script",
             "they are listed as though a script could call them, which it cannot"
    end

    test "and asking about one by name says so too", %{frame: frame} do
      assert {:reply, response, ^frame} = ToolDocs.execute(%{name: "browser_navigate"}, frame)

      body = text(response)
      assert body =~ "# browser_navigate"
      assert body =~ "run_browser_script"
    end
  end

  describe "what the machine says its tools take" do
    setup do
      scope = full_scope_fixture()
      {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)

      # The shape a machine really reports, recorded the way the join records
      # it: names for scoping, and a description plus a JSON Schema per name.
      :ok =
        CodeMySpec.WorkingCopies.record_machine_tools(copy, ~w(browser_wait_for_text), %{
          "browser_wait_for_text" => %{
            "description" => "Wait until specific text appears on the page",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{
                "text" => %{"type" => "string", "description" => "Text to wait for on the page"},
                "timeout" => %{"type" => "number", "description" => "Timeout in milliseconds"}
              },
              "required" => ["text"]
            }
          }
        })

      %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
    end

    test "reaches the catalog entry instead of a placeholder", %{scope: scope} do
      tool = Layer.machine_catalog(scope, nil, 60_000)["browser_wait_for_text"]

      assert tool.description == "Wait until specific text appears on the page"
      assert tool.schema["required"] == ["text"]

      refute tool.description =~ "tool_docs", """
      The entry still points at tool_docs for its arguments, which is the circle
      this closed: the description said to ask tool_docs, and tool_docs had
      nothing to answer with because the schemas were mapped away in
      `list_tool_names/1`.
      """
    end

    test "and tool_docs renders them the way it renders ours", %{frame: frame} do
      assert {:reply, response, ^frame} =
               ToolDocs.execute(%{name: "browser_wait_for_text"}, frame)

      body = text(response)

      assert body =~ "# browser_wait_for_text"
      assert body =~ "Wait until specific text appears on the page"
      assert body =~ "text", "the argument it cannot be called without is not documented"
      assert body =~ "timeout"

      # Rendered by `Docs`, not by a paragraph written here — so the example is
      # runnable and the required arguments are marked as such.
      assert body =~ "```lua"
      assert body =~ "run_browser_script"
    end

    test "a machine that has not reported them still gets a page", %{scope: scope} do
      {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
      :ok = CodeMySpec.WorkingCopies.record_machine_tools(copy, ~w(browser_click), nil)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ToolDocs.execute(%{name: "browser_click"}, frame)

      body = text(response)
      assert body =~ "# browser_click"

      assert body =~ "has not reported", """
      A harness older than the docs column gets a page that says so. Silence
      here reads as a tool with no arguments, which is a different and wrong
      thing.
      """
    end

    test "names still record when a harness sends no docs", %{scope: scope} do
      {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
      :ok = CodeMySpec.WorkingCopies.record_machine_tools(copy, ~w(browser_click), nil)

      # Scoping is read off the names, so an old harness must not lose them —
      # and the docs it did send earlier are left alone rather than blanked.
      assert Layer.machine_tool_names(scope) == ~w(browser_click)
      {:ok, reread} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)
      assert Map.has_key?(reread.machine_tool_docs, "browser_wait_for_text")
    end
  end
end
