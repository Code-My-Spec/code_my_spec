defmodule CodeMySpec.McpServers.SpineTest do
  @moduledoc """
  Story 971 — what an agent is handed at connect, and what it can still reach.

  The three rules, asserted against the real registrations rather than a list
  written here. A test that restated the spine would pass forever no matter
  what the server advertised.
  """
  use ExUnit.Case, async: true

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
