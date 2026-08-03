defmodule CodeMySpec.Requirements.RegistryTest do
  @moduledoc """
  The entry point for requirement definitions.

  `has_children?/1` lives here rather than on `Components.Registry` because it
  answers its question by reading the graph template. Keeping it beside the type
  table would have meant `cms_scan` — which holds that table so the light
  harness can classify files without a database — calling back into the
  application that consumes it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Registry

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
end
