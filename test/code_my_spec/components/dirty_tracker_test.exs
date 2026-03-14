defmodule CodeMySpec.Components.DirtyTrackerTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Components.DirtyTracker

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  setup do
    scope = full_scope_fixture(%{module_name: "CodeMySpec"})
    %{scope: scope}
  end

  describe "analysis_dirty?/1" do
    test "returns false when files_changed_at is nil", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Foo"})
      refute DirtyTracker.analysis_dirty?(component)
    end

    test "returns true when files_changed_at is set and never analyzed", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Bar"})
      {:ok, component} = Components.update_component(scope, component, %{files_changed_at: DateTime.utc_now()})
      assert DirtyTracker.analysis_dirty?(component)
    end

    test "returns true when files changed after last analysis", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Baz"})
      past = ~U[2026-03-06 12:00:00Z]
      future = ~U[2026-03-07 12:00:00Z]

      {:ok, component} =
        Components.update_component(scope, component, %{
          files_changed_at: future,
          last_analyzed_at: past
        })

      assert DirtyTracker.analysis_dirty?(component)
    end

    test "returns false when last analysis is after files_changed_at", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Qux"})
      past = ~U[2026-03-06 12:00:00Z]
      future = ~U[2026-03-07 12:00:00Z]

      {:ok, component} =
        Components.update_component(scope, component, %{
          files_changed_at: past,
          last_analyzed_at: future
        })

      refute DirtyTracker.analysis_dirty?(component)
    end
  end

  describe "dirty_for_analysis/1" do
    test "returns only analysis-dirty components", %{scope: scope} do
      clean = component_fixture(scope, %{module_name: "CodeMySpec.Clean"})
      dirty = component_fixture(scope, %{module_name: "CodeMySpec.Dirty"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _clean} =
        Components.update_component(scope, clean, %{
          files_changed_at: now,
          last_analyzed_at: now
        })

      {:ok, _dirty} =
        Components.update_component(scope, dirty, %{
          files_changed_at: now
        })

      result = DirtyTracker.dirty_for_analysis(scope)
      assert length(result) == 1
      assert hd(result).id == dirty.id
    end
  end

  describe "record_analysis/2" do
    test "marks components clean for analysis", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Analyzed"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, component} =
        Components.update_component(scope, component, %{files_changed_at: now})

      assert DirtyTracker.analysis_dirty?(component)

      DirtyTracker.record_analysis(scope, [component])

      result = DirtyTracker.dirty_for_analysis(scope)
      assert result == []
    end
  end

  describe "build_path_index/2" do
    test "maps file paths to component ids", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "CodeMySpec.Accounts"})

      {path_map, files_map} = DirtyTracker.build_path_index([component], scope.active_project)

      assert Map.has_key?(path_map, "lib/code_my_spec/accounts.ex")
      assert path_map["lib/code_my_spec/accounts.ex"] == component.id
      assert Map.has_key?(files_map, component.id)
    end
  end
end
