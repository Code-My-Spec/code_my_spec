defmodule CodeMySpec.McpServers.SpineTest do
  @moduledoc """
  Story 971 — what an agent is handed at connect, and what it can still reach.

  The three rules, asserted against the real registrations rather than a list
  written here. A test that restated the spine would pass forever no matter
  what the server advertised.
  """
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools}

  defp advertised, do: MapSet.new(LocalServer.__components__(), & &1.name)
  defp scriptable, do: MapSet.new(ScriptableTools.__components__(), & &1.name)

  describe "the list an agent receives at connect" do
    test "is the spine, not every tool" do
      assert MapSet.size(advertised()) <= 20,
             "the point of the story is a short list; got #{MapSet.size(advertised())}"

      assert "run_script" in advertised()
      assert "tool_docs" in advertised()
      assert "get_next_requirement" in advertised()
    end

    test "and costs a fraction of what it cost" do
      # Measured against the real registrations, the way the 82,591-byte figure
      # this story exists to change was measured.
      #
      # The spine came out at 15,615 bytes, not the ~2,000 the index-only
      # estimate suggested, and the reason is worth knowing: the tools that had
      # to stay are the expensive ones. `ask_user` alone is 2,398 bytes, and
      # `show_in_panel` and `assign_subagent` are not far behind. The saving is
      # 81%, not 90%.
      payload =
        LocalServer.__components__()
        |> Enum.map(&%{name: &1.name, description: &1.description, inputSchema: &1.input_schema})
        |> Jason.encode!()

      assert byte_size(payload) < 20_000,
             "the advertised list is #{byte_size(payload)} bytes, against 82,591 before " <>
               "this story and 15,615 when it landed. Something large came back onto " <>
               "the spine."
    end
  end

  describe "a client that connected before the change" do
    test "is told the tool moved, not that it does not exist" do
      # A tool list is cached at connect, so a session that joined before this
      # story still holds all 111 names and will call one that has moved.
      # Anubis answers method_not_found, which is true and unhelpful.
      request = %{
        "method" => "tools/call",
        "params" => %{"name" => "list_stories", "arguments" => %{}}
      }

      assert {:reply, reply, _frame} = LocalServer.handle_request(request, %Frame{})

      # Asserted on what the transport is handed, not on a struct this test
      # just converted itself. The first version returned `%Response{}` and
      # checked `Response.to_protocol(response)` — which passes whatever the
      # reply is, because the test did the conversion the server had skipped.
      # On the real endpoint `JSON.Encoder` had no implementation for it and
      # the **session terminated**, which is worse than the method_not_found
      # this exists to improve on.
      assert is_map(reply) and not is_struct(reply),
             "the reply must already be in protocol form; got #{inspect(reply) |> String.slice(0, 120)}"

      assert {:ok, _json} = Jason.encode(reply),
             "the transport JSON-encodes this; a value it cannot encode kills the session"

      assert reply["isError"]

      text = reply |> Map.get("content") |> hd() |> Map.get("text")

      assert text =~ "moved to code mode"
      assert text =~ "run_script"

      refute text =~ "method_not_found",
             "the agent is one run_script call away from the tool; saying only that it " <>
               "was not found sends it looking for a name that is not wrong"
    end

    test "and a name that never existed is still just not found" do
      request = %{
        "method" => "tools/call",
        "params" => %{"name" => "definitely_not_a_tool", "arguments" => %{}}
      }

      # Not our business — the redirect fires only for tools that really moved,
      # so a typo does not get told to script something that does not exist.
      assert {:error, _error, _frame} = LocalServer.handle_request(request, %Frame{})
    end
  end

  describe "nothing falls through the gap" do
    test "every tool is either advertised or scriptable" do
      both = MapSet.union(advertised(), scriptable())

      # The two lists are the whole surface. A tool in neither is one nobody
      # can call by any route, which is the failure this split could most
      # easily produce and the least likely to be noticed.
      assert MapSet.size(both) == MapSet.size(advertised()) + MapSet.size(scriptable()),
             "a tool is registered on both servers: " <>
               inspect(MapSet.intersection(advertised(), scriptable()) |> MapSet.to_list())

      assert MapSet.size(both) > 100,
             "the two lists together should still be the whole tool surface, got " <>
               "#{MapSet.size(both)}"
    end

    test "every tool a script may not call is advertised" do
      # The rule the story ends on. `Catalog` refuses to bind these, so one
      # that is also absent from the advertised list is reachable from nowhere.
      unreachable = Enum.reject(Catalog.excluded(), &(&1 in advertised()))

      assert unreachable == [],
             """
             These are excluded from scripts and not advertised either, so no
             route reaches them at all:

                 #{Enum.join(unreachable, "\n    ")}
             """
    end

    test "and no tool a script may not call is in the scriptable set" do
      leaked = Enum.filter(Catalog.excluded(), &(&1 in scriptable()))

      assert leaked == [], "excluded but scriptable: #{inspect(leaked)}"
    end
  end
end
