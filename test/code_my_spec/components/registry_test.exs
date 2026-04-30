defmodule CodeMySpec.Components.RegistryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Registry

  describe "has_children?/1" do
    test "true for context (template has :child-scoped defs)" do
      assert Registry.has_children?("context")
    end

    test "true for coordination_context (shares :context_graph template)" do
      assert Registry.has_children?("coordination_context")
    end

    test "true for live_context (template has :child-scoped defs)" do
      assert Registry.has_children?("live_context")
    end

    test "false for schema (template is :self only)" do
      refute Registry.has_children?("schema")
    end

    test "false for repository (uses :default_graph, no :child)" do
      refute Registry.has_children?("repository")
    end

    test "false for liveview (template is :self only)" do
      refute Registry.has_children?("liveview")
    end

    test "false for controller (uses :default_graph, no :child)" do
      refute Registry.has_children?("controller")
    end

    test "false for unknown type (falls back to default_graph)" do
      refute Registry.has_children?("does_not_exist")
    end
  end

  describe "dependency_order/1" do
    test "schema sorts first (closest to data)" do
      assert Registry.dependency_order("schema") == 0
    end

    test "behaviour sorts after schema" do
      assert Registry.dependency_order("behaviour") == 1
    end

    test "repository sorts after behaviour" do
      assert Registry.dependency_order("repository") == 2
    end

    test "service sorts after repository" do
      assert Registry.dependency_order("service") == 3
    end

    test "liveview, liveview_component, and json share UI tier" do
      assert Registry.dependency_order("liveview") == 4
      assert Registry.dependency_order("liveview_component") == 4
      assert Registry.dependency_order("json") == 4
    end

    test "unranked type falls back to neutral default (rendered after primitives)" do
      assert Registry.dependency_order("task") == 5
      assert Registry.dependency_order("genserver") == 5
    end

    test "unknown type falls back to neutral default" do
      assert Registry.dependency_order("does_not_exist") == 5
    end

    test "ordering is total — schemas precede liveviews" do
      assert Registry.dependency_order("schema") < Registry.dependency_order("liveview")
    end
  end
end
