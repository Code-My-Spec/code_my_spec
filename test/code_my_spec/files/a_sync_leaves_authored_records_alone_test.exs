defmodule CodeMySpec.Files.ASyncLeavesAuthoredRecordsAloneTest do
  @moduledoc """
  Components as records (3aeb66cf). A full sync treated spec files as the whole
  truth: it pruned every component no file named, and deleted every edge a
  spec's `## Dependencies` did not list. So an edge an agent added with
  `add_dependency`, or a component it created before writing any code, was
  undone by the next full sync. Step 7c: a sync reads no spec, so it touches
  no edge, and prunes only what it discovered.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Repo

  @web "MyApp.Web"
  @accounts "MyApp.Accounts"

  # A spec the scanner has read, naming `module` and declaring no dependencies.
  defp spec!(scope, module) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: ".code_my_spec/spec/#{Macro.underscore(module)}.spec.md",
      role: :spec,
      fingerprint: "sha-#{System.unique_integer([:positive])}",
      size: 100,
      valid: true,
      validation_errors: %{
        "data" => %{"module_name" => module, "type" => "context", "dependencies" => []}
      }
    })
  end

  defp full_sync(scope), do: {:ok, _} = ComponentSync.sync_from_files(scope)

  defp names(scope), do: scope |> Components.list_components() |> Enum.map(& &1.module_name)

  defp edges(scope),
    do:
      scope
      |> Components.list_dependencies()
      |> Enum.map(&{&1.source_component.module_name, &1.target_component.module_name})

  setup do
    scope = %{full_scope_fixture() | environment: nil, cwd: nil}
    web = component_fixture(scope, %{name: "Web", module_name: @web})
    accounts = component_fixture(scope, %{name: "Accounts", module_name: @accounts})
    spec!(scope, @web)
    spec!(scope, @accounts)
    %{scope: scope, web: web, accounts: accounts}
  end

  describe "an edge" do
    test "an authored one survives a spec that does not list it", ctx do
      {:ok, _} =
        Components.create_dependency(ctx.scope, %{
          source_component_id: ctx.web.id,
          target_component_id: ctx.accounts.id,
          provenance: :authored
        })

      full_sync(ctx.scope)

      assert edges(ctx.scope) == [{@web, @accounts}]
    end

    test "one with no provenance survives too: a spec says nothing any more", ctx do
      {:ok, _} =
        Components.create_dependency(ctx.scope, %{
          source_component_id: ctx.web.id,
          target_component_id: ctx.accounts.id
        })

      full_sync(ctx.scope)

      assert edges(ctx.scope) == [{@web, @accounts}]
    end
  end

  describe "a component no file names" do
    test "an authored one is kept", ctx do
      component_fixture(ctx.scope, %{
        name: "Billing",
        module_name: "MyApp.Billing",
        provenance: :authored
      })

      full_sync(ctx.scope)

      assert "MyApp.Billing" in names(ctx.scope)
    end

    test "one with no provenance is kept, and stays unmarked", ctx do
      component_fixture(ctx.scope, %{name: "Billing", module_name: "MyApp.Billing"})

      full_sync(ctx.scope)

      assert %{provenance: nil} =
               ctx.scope
               |> Components.list_components()
               |> Enum.find(&(&1.module_name == "MyApp.Billing"))
    end
  end

  test "re-upserting an authored component without provenance keeps the mark", ctx do
    %{} =
      Components.upsert_component(ctx.scope, %{
        name: "Billing",
        module_name: "MyApp.Billing",
        provenance: :authored
      })

    %{} =
      Components.upsert_component(ctx.scope, %{
        name: "Billing",
        module_name: "MyApp.Billing",
        description: "again"
      })

    assert %{provenance: :authored} =
             ctx.scope
             |> Components.list_components()
             |> Enum.find(&(&1.module_name == "MyApp.Billing"))
  end
end
