defmodule CodeMySpec.Requirements.ACopyGraphReadsAsTheProjectionDoesTest do
  @moduledoc """
  A checkout's graph read from the project's topology and record verdicts, its
  overlay and its gates is the graph its stored rows give.

  Nothing per checkout is read: membership comes from the templates, file
  verdicts from the harness's report, the three placement gates are settled on
  read. Where there is no report to read, file verdicts are unsatisfied and say
  why: a checkout that has not reported, or no checkout at all.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Paths
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{CopyGraph, CopyOverlay, IncrementalGraph}
  alias CodeMySpec.Requirements.{Preloader, Projection, Topology, Verification}

  setup do
    scope = full_scope_fixture()
    context = component_fixture(scope, %{type: "context", module_name: "MyApp.Billing"})

    component_fixture(scope, %{
      type: "schema",
      module_name: "MyApp.Billing.Invoice",
      parent_component_id: context.id
    })

    story = story_fixture(scope, %{ready_for_dev: true})
    first = criterion_fixture(scope, story)
    criterion_fixture(scope, story)

    for {path, role, errors, component_id, criterion} <- [
          {"lib/my_app/billing.ex", :implementation, nil, context.id, nil},
          {Paths.decisions_index(), :architecture, nil, nil, nil},
          {"test/spex/#{story.number}_billing/criterion_#{first.number}_spex.exs", :bdd_spec,
           %{"data" => %{"criterion" => first.number}}, nil, first.number}
        ] do
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: scope.active_working_copy_id,
        path: path,
        role: role,
        valid: true,
        validation_errors: errors,
        criterion_number: criterion,
        component_id: component_id
      })
    end

    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])

    %{scope: scope}
  end

  test "with the copy's report, every node, verdict and edge is the stored graph's",
       %{scope: scope} do
    {:ok, _} = CopyOverlay.report(scope, report(scope))
    ctx = Preloader.read_context(scope)

    {stored, stored_edges} = Projection.load(scope, ctx)
    {read, read_edges} = CopyGraph.load(scope, ctx)

    assert length(stored) > 10, "the premise did not hold: #{length(stored)} stored nodes"
    assert behaviour(read) == behaviour(stored)
    assert edges(read_edges) == edges(stored_edges)
  end

  test "a copy that has not reported reads its file verdicts as awaiting it", %{scope: scope} do
    {nodes, _edges} = CopyGraph.load(scope, Preloader.read_context(scope))

    assert %{satisfied: false, details: %{"reason" => "awaiting this copy's report"}} =
             Enum.find(nodes, &(&1.name == "technical_strategy"))
  end

  test "nil with no default copy reads file verdicts as no checkout reporting", %{scope: scope} do
    {:ok, _} = CopyOverlay.report(scope, report(scope))
    unscoped = %{scope | active_working_copy_id: nil}

    {nodes, _edges} = CopyGraph.load(unscoped, Preloader.read_context(unscoped))

    assert %{satisfied: false, details: %{"reason" => "no checkout has reported files"}} =
             Enum.find(nodes, &(&1.name == "technical_strategy"))
  end

  # What the copy's harness would report: its files, as scanned.
  defp report(scope) do
    entries =
      Repo.all(from(f in FileRecord, where: f.working_copy_id == ^scope.active_working_copy_id))
      |> Enum.map(&Map.take(&1, [:path, :role, :valid, :validation_errors, :size]))

    records = scope |> CopyOverlay.records() |> Jason.encode!() |> Jason.decode!()
    read_model = %{Files.read_model(scope) | overlay_records: records}

    %{"read_model" => "test", "verdicts" => CopyOverlay.verdicts(entries, read_model)}
  end

  defp behaviour(nodes),
    do: Map.new(nodes, &{Topology.node_key(&1), Verification.behavior(&1)})

  defp edges(edges), do: MapSet.new(edges, &{&1.from, &1.to})
end
