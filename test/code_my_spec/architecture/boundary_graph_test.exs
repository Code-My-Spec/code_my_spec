defmodule CodeMySpec.Architecture.BoundaryGraphTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Architecture.BoundaryGraph
  alias CodeMySpec.Components
  alias CodeMySpec.Files.{DependencyEvidence, File}
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    for name <- ~w(App.Web App.Accounts App.Billing App.Repo) do
      scanned_file(scope, name, "defmodule #{name} do\n  use Boundary\nend\n")
    end

    ids =
      for name <- ~w(App.Web App.Accounts App.Accounts.Store App.Billing App.Repo App.Loose),
          into: %{},
          do: {name, component(scope, name).id}

    for {from, to} <- [
          {"App.Web", "App.Accounts"},
          {"App.Web", "App.Accounts.Store"},
          {"App.Accounts.Store", "App.Repo"},
          {"App.Billing", "App.Accounts"},
          {"App.Accounts", "App.Billing"},
          {"App.Loose", "App.Repo"}
        ] do
      {:ok, _} =
        Components.create_dependency(scope, %{
          source_component_id: ids[from],
          target_component_id: ids[to],
          provenance: :discovered,
          in_code: true
        })
    end

    %{graph: BoundaryGraph.build(scope)}
  end

  test "one node per declared boundary, a child module rolled up to its boundary", %{graph: graph} do
    assert Enum.sort(Enum.map(graph.nodes, & &1.key)) ==
             ~w(App.Accounts App.Billing App.Repo App.Web)

    assert %{attributes: %{weight: 2}} = edge(graph, "App.Web", "App.Accounts")
    assert edge(graph, "App.Accounts", "App.Repo")
    assert graph.summary.unowned_modules == 1
  end

  test "layers by depth, with a cycle sharing one layer", %{graph: graph} do
    assert layer(graph, "App.Web") == 0
    assert layer(graph, "App.Accounts") == 1
    assert layer(graph, "App.Billing") == 1
    assert layer(graph, "App.Repo") == 2

    assert graph.summary.depth == 2
    assert List.first(graph.summary.longest_chain) == "App.Web"
    assert List.last(graph.summary.longest_chain) == "App.Repo"
  end

  test "a cycle is named and its edges are flagged", %{graph: graph} do
    assert graph.summary.cycles == [["App.Accounts", "App.Billing"]]
    assert edge(graph, "App.Accounts", "App.Billing").attributes.cycle
    assert edge(graph, "App.Billing", "App.Accounts").attributes.cycle
    refute edge(graph, "App.Web", "App.Accounts").attributes.cycle
  end

  test "each layer takes its own colour, a cycle stays red", %{graph: graph} do
    assert color(graph, "App.Web") != color(graph, "App.Repo")
    assert color(graph, "App.Accounts") == "#ef4444"
    assert graph.edge_alpha < 1
  end

  test "a wide layer wraps into rows of eight, no two boundaries in one spot" do
    scope = full_scope_fixture()
    callees = for i <- 1..12, do: "App.Leaf#{i}"

    for name <- ["App.Top" | callees] do
      scanned_file(scope, name, "defmodule #{name} do\n  use Boundary\nend\n")
    end

    top = component(scope, "App.Top")

    for name <- callees do
      {:ok, _} =
        Components.create_dependency(scope, %{
          source_component_id: top.id,
          target_component_id: component(scope, name).id,
          provenance: :discovered,
          in_code: true
        })
    end

    graph = BoundaryGraph.build(scope)
    leaves = Enum.filter(graph.nodes, &(&1.key in callees))
    rows = Enum.group_by(leaves, & &1.attributes.y)

    assert map_size(rows) == 2
    assert rows |> Map.values() |> Enum.map(&length/1) |> Enum.sort() == [4, 8]

    assert graph.nodes |> Enum.map(&{&1.attributes.x, &1.attributes.y}) |> Enum.uniq() |> length() ==
             13
  end

  test "a project whose scan recorded no declarations says so" do
    assert %{summary: %{declarations_recorded: false, boundaries: 0}} =
             BoundaryGraph.build(full_scope_fixture())
  end

  defp edge(graph, from, to), do: Enum.find(graph.edges, &(&1.source == from and &1.target == to))
  defp color(graph, key), do: Enum.find(graph.nodes, &(&1.key == key)).attributes.color
  defp layer(graph, key), do: Enum.find(graph.nodes, &(&1.key == key)).attributes.layer

  defp component(scope, module_name) do
    component_fixture(scope, %{
      name: module_name |> String.split(".") |> List.last(),
      module_name: module_name,
      type: "module",
      provenance: :discovered
    })
  end

  defp scanned_file(scope, module_name, source) do
    Repo.insert!(%File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: "lib/#{Macro.underscore(module_name)}.ex",
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
