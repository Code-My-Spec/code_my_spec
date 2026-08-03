defmodule CodeMySpec.Components.RegistryTest do
  @moduledoc """
  What a component type *is* — a plain table and lookups over it, no database
  and no requirement definitions. `has_children?/1` moved to
  `Requirements.RegistryTest` along with the function, because answering it
  means reading the requirement graph template.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Registry

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
