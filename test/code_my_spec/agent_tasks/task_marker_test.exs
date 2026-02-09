defmodule CodeMySpec.AgentTasks.TaskMarkerTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.TaskMarker

  describe "build/2" do
    test "returns HTML comment with type and component" do
      result = TaskMarker.build("ComponentTest", "MetricFlow.Accounts.User")

      assert result == ~s(<!-- cms:task type="ComponentTest" component="MetricFlow.Accounts.User" -->)
    end

    test "handles simple module names" do
      result = TaskMarker.build("ContextSpec", "Accounts")

      assert result =~ "ContextSpec"
      assert result =~ "Accounts"
    end
  end

  describe "extract/1" do
    test "extracts type and component from valid marker" do
      text = ~s(<!-- cms:task type="ComponentCode" component="MetricFlow.Accounts.User" -->)

      assert {:ok, %{type: "ComponentCode", component: "MetricFlow.Accounts.User"}} =
               TaskMarker.extract(text)
    end

    test "extracts marker embedded in surrounding text" do
      text = """
      Some preamble text.

      <!-- cms:task type="ContextSpec" component="MetricFlow.Sessions" -->

      Generate a Phoenix component spec...
      """

      assert {:ok, %{type: "ContextSpec", component: "MetricFlow.Sessions"}} =
               TaskMarker.extract(text)
    end

    test "returns :none when no marker present" do
      assert :none = TaskMarker.extract("Just some regular text")
    end

    test "returns :none for empty string" do
      assert :none = TaskMarker.extract("")
    end

    test "roundtrips through build and extract" do
      marker = TaskMarker.build("ComponentTest", "MetricFlow.Accounts.User")

      assert {:ok, %{type: "ComponentTest", component: "MetricFlow.Accounts.User"}} =
               TaskMarker.extract(marker)
    end
  end
end
