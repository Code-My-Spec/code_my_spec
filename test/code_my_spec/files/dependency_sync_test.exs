defmodule CodeMySpec.Files.DependencySyncTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.{ComponentSync, DependencyEvidence, File}
  alias CodeMySpec.Repo

  setup do
    %{scope: %{full_scope_fixture() | environment: nil, cwd: nil}}
  end

  test "stored call evidence creates an edge without reopening source files", %{scope: scope} do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")

    scanned_file(scope, "lib/my_app/billing.ex", "MyApp.Billing", """
    defmodule MyApp.Billing do
      alias MyApp.Accounts
      def charge(order), do: Accounts.fetch(order)
    end
    """)

    assert {:ok, _} = ComponentSync.sync_from_files(scope)

    assert %{provenance: :discovered, in_code: true} =
             Components.get_dependency_between(scope, billing.id, accounts.id)
  end

  test "an unused alias has no dependency evidence", %{scope: scope} do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")

    scanned_file(scope, "lib/my_app/billing.ex", "MyApp.Billing", """
    defmodule MyApp.Billing do
      alias MyApp.Accounts
      @account_module Accounts
    end
    """)

    assert {:ok, _} = ComponentSync.sync_from_files(scope)
    assert is_nil(Components.get_dependency_between(scope, billing.id, accounts.id))
  end

  test "malformed evidence leaves the prior discovered edge unchanged", %{scope: scope} do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")

    {:ok, original} =
      Components.create_dependency(scope, %{
        source_component_id: billing.id,
        target_component_id: accounts.id,
        provenance: :discovered,
        in_code: true
      })

    scanned_file(
      scope,
      "lib/my_app/billing.ex",
      "MyApp.Billing",
      "defmodule MyApp.Billing do\n def call(\nend"
    )

    assert {:ok, _} = ComponentSync.sync_from_files(scope)

    assert %{id: id, provenance: :discovered, in_code: true} =
             Components.get_dependency_between(scope, billing.id, accounts.id)

    assert id == original.id
  end

  test "valid source without calls removes observed-only edges and clears authored code status",
       %{scope: scope} do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")
    notifications = component(scope, "MyApp.Notifications")

    {:ok, _} =
      Components.create_dependency(scope, %{
        source_component_id: billing.id,
        target_component_id: accounts.id,
        provenance: :authored,
        in_code: true
      })

    {:ok, _} =
      Components.create_dependency(scope, %{
        source_component_id: billing.id,
        target_component_id: notifications.id,
        provenance: :discovered,
        in_code: true
      })

    scanned_file(scope, "lib/my_app/billing.ex", "MyApp.Billing", """
    defmodule MyApp.Billing do
      def charge(order), do: {:ok, order}
    end
    """)

    assert {:ok, _} = ComponentSync.sync_from_files(scope)

    assert is_nil(Components.get_dependency_between(scope, billing.id, notifications.id))

    assert %{provenance: :authored, in_code: false} =
             Components.get_dependency_between(scope, billing.id, accounts.id)
  end

  test "evidence from multiple source modules stays attached to each source and project", %{
    scope: scope
  } do
    billing = component(scope, "MyApp.Billing")
    reports = component(scope, "MyApp.Reports")
    accounts = component(scope, "MyApp.Accounts")
    notifications = component(scope, "MyApp.Notifications")

    scanned_file(scope, "lib/my_app/billing.ex", "MyApp.Billing", """
    defmodule MyApp.Billing do
      alias MyApp.Accounts
      def charge(order), do: Accounts.fetch(order)
    end
    """)

    scanned_file(scope, "lib/my_app/reports.ex", "MyApp.Reports", """
    defmodule MyApp.Reports do
      alias MyApp.Notifications
      def publish(report), do: Notifications.publish(report)
    end
    """)

    other_scope = %{full_scope_fixture() | environment: nil, cwd: nil}
    other_billing = component(other_scope, "MyApp.Billing")
    other_accounts = component(other_scope, "MyApp.Accounts")

    {:ok, other_edge} =
      Components.create_dependency(other_scope, %{
        source_component_id: other_billing.id,
        target_component_id: other_accounts.id,
        provenance: :discovered,
        in_code: true
      })

    assert {:ok, _} = ComponentSync.sync_from_files(scope)

    assert %{source_component_id: billing_id, target_component_id: accounts_id} =
             Components.get_dependency_between(scope, billing.id, accounts.id)

    assert billing_id == billing.id
    assert accounts_id == accounts.id

    assert %{source_component_id: reports_id, target_component_id: notifications_id} =
             Components.get_dependency_between(scope, reports.id, notifications.id)

    assert reports_id == reports.id
    assert notifications_id == notifications.id

    assert %{id: other_edge_id, in_code: true} =
             Components.get_dependency_between(other_scope, other_billing.id, other_accounts.id)

    assert other_edge_id == other_edge.id
  end

  test "a full sync does not erase edges when a legacy file has no stored observation", %{
    scope: scope
  } do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")

    {:ok, original} =
      Components.create_dependency(scope, %{
        source_component_id: billing.id,
        target_component_id: accounts.id,
        provenance: :discovered,
        in_code: true
      })

    Repo.insert!(%File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: "lib/my_app/billing.ex",
      role: :implementation,
      valid: true,
      validation_errors: %{"data" => %{"module_name" => "MyApp.Billing"}}
    })

    assert {:ok, _} = ComponentSync.sync_from_files(scope)

    assert %{id: id, provenance: :discovered, in_code: true} =
             Components.get_dependency_between(scope, billing.id, accounts.id)

    assert id == original.id
  end

  test "an unresolved target does not prove a previous call disappeared", %{scope: scope} do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")

    {:ok, original} =
      Components.create_dependency(scope, %{
        source_component_id: billing.id,
        target_component_id: accounts.id,
        provenance: :discovered,
        in_code: true
      })

    scanned_file(scope, "lib/my_app/billing.ex", "MyApp.Billing", """
    defmodule MyApp.Billing do
      def call(module), do: module.fetch()
    end
    """)

    assert {:ok, %{dependency_observation: %{status: :partial}}} =
             ComponentSync.sync_from_files(scope)

    assert %{id: id, in_code: true} =
             Components.get_dependency_between(scope, billing.id, accounts.id)

    assert id == original.id
  end

  test "a dependency report is read-only", %{scope: scope} do
    billing = component(scope, "MyApp.Billing")
    accounts = component(scope, "MyApp.Accounts")

    scanned_file(scope, "lib/my_app/billing.ex", "MyApp.Billing", """
    defmodule MyApp.Billing do
      def call, do: MyApp.Accounts.fetch()
    end
    """)

    report = ComponentSync.dependency_report(scope)
    assert report.additions == [{billing.id, accounts.id}]
    assert report.unavailable == []
    assert is_nil(Components.get_dependency_between(scope, billing.id, accounts.id))
  end

  defp component(scope, module_name) do
    component_fixture(scope, %{
      name: module_name |> String.split(".") |> List.last(),
      module_name: module_name,
      type: "context",
      provenance: :authored
    })
  end

  defp scanned_file(scope, path, module_name, source) do
    Repo.insert!(%File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :implementation,
      valid: true,
      validation_errors: %{
        "data" => %{
          "module_name" => module_name,
          "dependency_evidence" => DependencyEvidence.extract(source)
        }
      }
    })
  end
end
