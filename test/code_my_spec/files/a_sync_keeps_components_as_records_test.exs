defmodule CodeMySpec.Files.ASyncKeepsComponentsAsRecordsTest do
  @moduledoc """
  Components as records (3aeb66cf). A sync parses no spec, leaves existing
  components as they are, creates new modules as discovered, and prunes only
  discovered components whose code is gone. Step 4 did this for frozen
  projects; step 7c made it the only sync, so a freeze changes nothing here.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Repo

  defp file!(scope, role, path, data) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: role,
      fingerprint: "sha-#{System.unique_integer([:positive])}",
      size: 100,
      valid: true,
      validation_errors: %{"data" => data}
    })
  end

  defp spec!(scope, module, attrs) do
    file!(
      scope,
      :spec,
      ".code_my_spec/spec/#{Macro.underscore(module)}.spec.md",
      Map.merge(%{"module_name" => module}, attrs)
    )
  end

  defp code!(scope, module),
    do:
      file!(scope, :implementation, "lib/#{Macro.underscore(module)}.ex", %{
        "module_name" => module
      })

  defp another_copy!(scope, seen_at) do
    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "copy #{System.unique_integer([:positive])}",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    Repo.update_all(from(w in CodeMySpec.WorkingCopies.WorkingCopy, where: w.id == ^copy.id),
      set: [last_seen_at: seen_at]
    )

    copy
  end

  defp by_name(scope), do: Map.new(Components.list_components(scope), &{&1.module_name, &1})

  defp edges(scope),
    do:
      scope
      |> Components.list_dependencies()
      |> Enum.map(&{&1.source_component.module_name, &1.target_component.module_name})

  setup do
    scope = %{full_scope_fixture() | environment: nil, cwd: nil}

    accounts =
      component_fixture(scope, %{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        description: "As authored",
        provenance: :authored
      })

    component_fixture(scope, %{
      name: "Web",
      module_name: "MyApp.Web",
      type: "context",
      provenance: :authored
    })

    # The spec now disagrees with the record about everything it can say.
    spec!(scope, "MyApp.Accounts", %{
      "type" => "module",
      "description" => "Rewritten in the spec",
      "dependencies" => ["MyApp.Web"]
    })

    code!(scope, "MyApp.Accounts")
    %{scope: scope, accounts: accounts}
  end

  describe "every project" do
    test "leaves an existing component as it is, whatever its spec says", ctx do
      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      accounts = by_name(ctx.scope)["MyApp.Accounts"]
      assert accounts.type == "context"
      assert accounts.description == "As authored"
      assert edges(ctx.scope) == []
    end

    test "creates a module code names as discovered, under its parent", ctx do
      code!(ctx.scope, "MyApp.Accounts.Helper")

      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      helper = by_name(ctx.scope)["MyApp.Accounts.Helper"]
      assert helper.provenance == :discovered
      assert helper.parent_component_id == ctx.accounts.id
    end

    test "prunes a discovered component whose code is gone, never an authored one", ctx do
      component_fixture(ctx.scope, %{
        name: "Gone",
        module_name: "MyApp.Gone",
        provenance: :discovered
      })

      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      names = Map.keys(by_name(ctx.scope))
      refute "MyApp.Gone" in names
      assert "MyApp.Web" in names
    end

    test "keeps a discovered component whose code is still on a live checkout", ctx do
      component_fixture(ctx.scope, %{
        name: "Feature",
        module_name: "MyApp.Feature",
        provenance: :discovered
      })

      live_copy = another_copy!(ctx.scope, DateTime.utc_now())
      code!(%{ctx.scope | active_working_copy_id: live_copy.id}, "MyApp.Feature")

      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      assert "MyApp.Feature" in Map.keys(by_name(ctx.scope))
    end

    test "prunes one whose code is only on a stale checkout", ctx do
      component_fixture(ctx.scope, %{
        name: "Old",
        module_name: "MyApp.Old",
        provenance: :discovered
      })

      stale = another_copy!(ctx.scope, DateTime.add(DateTime.utc_now(), -30 * 86_400))
      code!(%{ctx.scope | active_working_copy_id: stale.id}, "MyApp.Old")

      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      refute "MyApp.Old" in Map.keys(by_name(ctx.scope))
    end

    test "keeps a discovered component something authored points at", ctx do
      linked =
        component_fixture(ctx.scope, %{
          name: "Linked",
          module_name: "MyApp.Linked",
          provenance: :discovered
        })

      {:ok, _} =
        Components.create_dependency(ctx.scope, %{
          source_component_id: ctx.accounts.id,
          target_component_id: linked.id,
          provenance: :authored
        })

      storied =
        component_fixture(ctx.scope, %{
          name: "Storied",
          module_name: "MyApp.Storied",
          provenance: :discovered
        })

      story = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope)
      {:ok, _} = CodeMySpec.Stories.set_story_component(ctx.scope, story, storied.id)

      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      names = Map.keys(by_name(ctx.scope))
      assert "MyApp.Linked" in names
      assert "MyApp.Storied" in names
    end

    # A row from before provenance existed, which only legacy data produces —
    # an unfrozen project's whole graph, or LiveCopies, created after the freeze.
    test "marks an unmarked component live code names as discovered, and leaves the rest", ctx do
      component_fixture(ctx.scope, %{name: "Coded", module_name: "MyApp.Coded"})
      component_fixture(ctx.scope, %{name: "Designed", module_name: "MyApp.Designed"})
      code!(ctx.scope, "MyApp.Coded")

      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      components = by_name(ctx.scope)
      assert components["MyApp.Coded"].provenance == :discovered
      assert components["MyApp.Designed"].provenance == nil
    end

    test "still links files to their component", ctx do
      {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

      assert [_ | _] = CodeMySpec.Files.list_component_files(ctx.scope, ctx.accounts.id)
    end
  end

  test "a spec-only component survives a sync, still unmarked", ctx do
    component_fixture(ctx.scope, %{name: "Planned", module_name: "MyApp.Planned"})
    spec!(ctx.scope, "MyApp.Planned", %{"type" => "context"})

    {:ok, _} = ComponentSync.sync_from_files(ctx.scope)

    assert %{provenance: nil} = by_name(ctx.scope)["MyApp.Planned"]
  end
end
