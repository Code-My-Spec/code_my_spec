defmodule CodeMySpec.CodeModeTest do
  @moduledoc """
  The runtime an agent's script runs in — story 970.

  Every test builds its own two-tool catalog rather than the server's 111. That
  is possible because `Catalog.from/2` takes the invoker as a parameter, which
  is what Boundary forced when it refused the first version reaching into
  `McpServers` — the refusal bought testability it was not aimed at.

  The safety tests assert on the *call*, not on presence. `Lua.new/1` sandboxes
  by replacing a function with one that raises, so `io` is still a table and
  `assert io == nil` would pass against a VM where `io.open` works fine.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.{Catalog, Result}

  defp catalog(tools) do
    Catalog.from(tools, fn tool -> Map.fetch!(tool, :invoke) end)
  end

  defp stories_catalog do
    catalog([
      %{
        name: "get_story",
        description: "Reads one story by id.\n\nUse list_stories to find ids.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "story_id" => %{"type" => "integer", "description" => "The story's id"}
          },
          "required" => ["story_id"]
        },
        invoke: fn
          %{"story_id" => 970} -> {:ok, %{"id" => 970, "title" => "I script the tools"}}
          %{"story_id" => id} -> {:error, "no story #{inspect(id)}"}
          _args -> {:error, "story_id is required"}
        end
      },
      %{
        name: "list_stories",
        description: "Lists every story.",
        input_schema: %{"type" => "object", "properties" => %{}},
        invoke: fn _args ->
          {:ok, [%{"id" => 970, "criteria" => 13}, %{"id" => 971, "criteria" => 4}]}
        end
      }
    ])
  end

  describe "calling tools from a script" do
    test "a tool is a function, and its result is a table" do
      result = CodeMode.eval(stories_catalog(), ~S[return get_story({ story_id = 970 }).title])

      refute Result.failed?(result)
      assert result.value == "I script the tools"
    end

    test "several calls, one turn — which is the whole point" do
      script = ~S"""
      local wanted = {}
      for _, story in ipairs(list_stories()) do
        if story.criteria > 5 then
          table.insert(wanted, get_story({ story_id = story.id }).title)
        end
      end
      return table.concat(wanted, ", ")
      """

      result = CodeMode.eval(stories_catalog(), script)

      refute Result.failed?(result)

      assert result.value == "I script the tools",
             "a list, a filter and a read per hit, in one call — three round trips and " <>
               "the arithmetic by hand otherwise"
    end

    test "an integer argument survives Lua having one number type" do
      # 970 arrives as 970.0. A tool whose schema says integer would reject it.
      result = CodeMode.eval(stories_catalog(), ~S[return get_story({ story_id = 970 }).id])
      assert result.value == 970
    end

    test "a tool that cannot answer returns nil and an error, and the script goes on" do
      script = ~S"""
      local found, missing = 0, {}
      for _, id in ipairs({ 970, 12345 }) do
        local story, err = get_story({ story_id = id })
        if story == nil then table.insert(missing, err.message) else found = found + 1 end
      end
      return found, missing[1]
      """

      result = CodeMode.eval(stories_catalog(), script)

      refute Result.failed?(result)

      assert [1, "no story 12345"] = result.value,
             "a miss must not end the script — reading twenty things and reporting the " <>
               "three that were missing is half of what code mode is for"
    end

    test "a tool that crashes is reported, not propagated" do
      exploding =
        catalog([
          %{
            name: "boom",
            description: "Always crashes.",
            input_schema: %{},
            invoke: fn _args -> raise "kaboom" end
          }
        ])

      result = CodeMode.eval(exploding, ~S[local ok, err = boom() return err.message])

      refute Result.failed?(result)
      assert result.value =~ "kaboom"
    end
  end

  describe "what a script cannot do" do
    test "reach the operating system or the disk" do
      for call <- [
            ~S[return pcall(io.open, "/etc/passwd", "r")],
            ~S[return pcall(os.execute, "echo hi")],
            ~S[return pcall(os.getenv, "HOME")],
            ~S[return pcall(require, "os")]
          ] do
        result =
          CodeMode.eval(
            %{},
            ~s[local ok, err = #{String.trim_leading(call, "return ")}\nreturn err]
          )

        assert result.value =~ "sandboxed",
               "#{call} was not refused — assert on the call, not on the name: sandboxing " <>
                 "replaces the function with one that raises, it does not delete it"
      end
    end

    test "run forever" do
      result = CodeMode.eval(%{}, ~S[while true do end], max_instructions: 50_000)

      assert Result.failed?(result)
      assert result.error.kind == :instruction_budget
    end

    test "recurse without bound" do
      result =
        CodeMode.eval(%{}, ~S[local function f() return f() end return f()], max_call_depth: 20)

      assert Result.failed?(result)
      assert result.error.kind == :call_depth
    end

    test "build an answer too big to carry" do
      # Not an infinite loop and not a blocked host call, so neither of the
      # other two limits sees it. The library's own default is 256 MiB — a
      # string this process would build and then try to put in a response.
      result = CodeMode.eval(%{}, ~S[return string.rep("x", 10000000)], max_string_bytes: 4096)

      assert Result.failed?(result)
      assert result.error.kind == :result_too_large
    end
  end

  describe "what comes back" do
    test "a script that will not compile says so without calling anything" do
      result = CodeMode.eval(stories_catalog(), "local a = 1\nthis is not lua\n")

      assert Result.failed?(result)
      assert result.error.kind == :compile
    end

    test "what the script printed, in order" do
      script = ~S"""
      print("checking 970")
      print("found", 13)
      return "done"
      """

      result = CodeMode.eval(stories_catalog(), script)

      assert result.value == "done"

      assert result.printed == ["checking 970", "found\t13"],
             "print must be captured — on a server the default writes to the log, where " <>
               "the agent that wrote the script never sees it"
    end

    test "a script run only for its writes returns nothing rather than an empty list" do
      result = CodeMode.eval(stories_catalog(), ~S[local _ = list_stories()])

      refute Result.failed?(result)
      assert result.value == nil
    end
  end

  describe "the catalog" do
    test "excludes tools that block on a person or spawn work" do
      built =
        catalog([
          %{name: "get_story", description: "", input_schema: %{}, invoke: fn _ -> {:ok, 1} end},
          %{name: "ask_user", description: "", input_schema: %{}, invoke: fn _ -> {:ok, 1} end},
          %{name: "start_agent", description: "", input_schema: %{}, invoke: fn _ -> {:ok, 1} end}
        ])

      assert Catalog.names(built) == ["get_story"]
    end

    test "and an excluded tool is simply not there to call" do
      built =
        catalog([
          %{name: "ask_user", description: "", input_schema: %{}, invoke: fn _ -> {:ok, 1} end}
        ])

      result = CodeMode.eval(built, ~S[return ask_user({ question = "hi" })])

      assert Result.failed?(result),
             "a loop over ask_user is twenty questions nobody agreed to answer"
    end
  end

  describe "documentation on demand" do
    test "the index is one line per tool, not every schema" do
      docs = CodeMode.docs(stories_catalog())

      assert docs =~ "get_story — Reads one story by id."
      assert docs =~ "list_stories — Lists every story."

      refute docs =~ "The story's id",
             "the index must not carry argument detail — looking it up instead is the " <>
               "reason this exists"
    end

    test "one tool by name gives its arguments and a runnable example" do
      docs = CodeMode.docs(stories_catalog(), name: "get_story")

      assert docs =~ "# get_story"
      assert docs =~ "story_id (integer, required) — The story's id"
      assert docs =~ ~s[get_story({ story_id = 1 })]
    end

    test "search finds a tool whose name the agent does not know" do
      docs = CodeMode.docs(stories_catalog(), search: "lists every")

      assert docs =~ "list_stories"
      refute docs =~ "get_story"
    end

    test "a near miss suggests the near ones" do
      docs = CodeMode.docs(stories_catalog(), name: "get_stories")

      assert docs =~ "Did you mean"
      assert docs =~ "get_story"
    end

    test "the index says which tools are not callable, so their absence is explained" do
      docs = CodeMode.docs(stories_catalog())
      assert docs =~ "ask_user"
    end
  end
end
