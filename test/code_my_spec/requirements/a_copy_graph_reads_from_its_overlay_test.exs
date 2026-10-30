defmodule CodeMySpec.Requirements.ACopyGraphReadsFromItsOverlayTest do
  @moduledoc """
  A checkout's graph is read from the project's topology and record verdicts,
  its overlay and its gates; nothing is stored per checkout.

  Membership comes from the templates, file verdicts from the harness's report
  when it answers the current records, else from the copy's File rows; the
  three placement gates are settled on read. `nil` with no default copy says no
  checkout has reported files.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Paths
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{CopyGraph, CopyOverlay, IncrementalGraph}
  alias CodeMySpec.Requirements.{Preloader, Topology, Verification}
  alias CodeMySpec.Stories.{AcceptanceCriteria, Story}
  alias CodeMySpec.WorkingCopies

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

  test "a copy with files and no report reads the graph its report would give",
       %{scope: scope} do
    ctx = Preloader.read_context(scope)
    {unreported, unreported_edges} = CopyGraph.load(scope, ctx)

    {:ok, _} = CopyOverlay.report(scope, report(scope))
    {reported, reported_edges} = CopyGraph.load(scope, ctx)

    assert behaviour(unreported) == behaviour(reported)
    assert edges(unreported_edges) == edges(reported_edges)
  end

  test "a current report is what is served; a stale one is not", %{scope: scope} do
    ctx = Preloader.read_context(scope)
    {:ok, _} = CopyOverlay.report(scope, flipped(report(scope)))

    assert %{satisfied: false} = node(CopyGraph.load(scope, ctx), "technical_strategy"),
           "the report answers the records as they are, so it is served"

    {:ok, _} = CopyOverlay.report(scope, %{flipped(report(scope)) | "read_model" => "older"})

    assert %{satisfied: true} = node(CopyGraph.load(scope, ctx), "technical_strategy"),
           "a report for other records is not served: the copy's files answer"
  end

  test "computed verdicts follow the copy's files", %{scope: scope} do
    ctx = Preloader.read_context(scope)
    assert %{satisfied: false} = node(CopyGraph.load(scope, ctx), "code_generation")

    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: ".code_my_spec/tasks/code_generation.sh",
      role: :task_artifact,
      valid: true
    })

    assert %{satisfied: true} = node(CopyGraph.load(scope, ctx), "code_generation")
  end

  test "a copy with neither a report nor files reads as an empty checkout", %{scope: scope} do
    Repo.delete_all(
      from(f in FileRecord, where: f.working_copy_id == ^scope.active_working_copy_id)
    )

    assert %{satisfied: false, details: %{"reason" => "File missing: " <> _}} =
             node(CopyGraph.load(scope, Preloader.read_context(scope)), "technical_strategy")
  end

  test "nil reads the project's default copy, whatever else it has", %{scope: scope} do
    {:ok, _other} =
      WorkingCopies.issue(scope, nil, label: "Other", device: device_fixture(scope))

    {:ok, _} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{
        default_working_copy_id: scope.active_working_copy_id
      })

    unscoped = %{scope | active_working_copy_id: nil}

    assert %{satisfied: true} =
             node(
               CopyGraph.load(unscoped, Preloader.read_context(unscoped)),
               "technical_strategy"
             )
  end

  test "nil with no default copy reads the main copy's file verdicts", %{scope: scope} do
    {:ok, _other} =
      WorkingCopies.issue(scope, nil, label: "Other", device: device_fixture(scope))

    {:ok, _} = WorkingCopies.designate_main(scope, scope.active_working_copy_id)
    unscoped = %{scope | active_working_copy_id: nil}

    assert %{satisfied: true} =
             node(
               CopyGraph.load(unscoped, Preloader.read_context(unscoped)),
               "technical_strategy"
             )
  end

  test "nil reads a project's only checkout when none is designated", %{scope: scope} do
    unscoped = %{scope | active_working_copy_id: nil}

    assert %{satisfied: true} =
             node(
               CopyGraph.load(unscoped, Preloader.read_context(unscoped)),
               "technical_strategy"
             )
  end

  test "nil with several checkouts and none designated reads no checkout reporting",
       %{scope: scope} do
    {:ok, _other} =
      WorkingCopies.issue(scope, nil, label: "Other", device: device_fixture(scope))

    {:ok, _} = CopyOverlay.report(scope, report(scope))
    unscoped = %{scope | active_working_copy_id: nil}

    {nodes, _edges} = CopyGraph.load(unscoped, Preloader.read_context(unscoped))

    assert %{satisfied: false, details: %{"reason" => "no checkout has reported files"}} =
             Enum.find(nodes, &(&1.name == "technical_strategy"))
  end

  test "a story placed at another copy reads its file verdict there", %{scope: scope} do
    {:ok, other} =
      WorkingCopies.issue(scope, nil, label: "Other", device: device_fixture(scope))

    story = story_fixture(scope, %{ready_for_dev: true})
    Repo.update_all(from(s in Story, where: s.id == ^story.id), set: [working_copy_id: other.id])
    story = Repo.get!(Story, story.id)

    for criterion <- AcceptanceCriteria.list_story_criteria(scope, story.id) do
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: other.id,
        path: "test/spex/#{story.number}_placed/criterion_#{criterion.number}_spex.exs",
        role: :bdd_spec,
        valid: true,
        validation_errors: %{"data" => %{"criterion" => criterion.number}},
        criterion_number: criterion.number
      })
    end

    assert {[%{satisfied: true, entity_id: id}], _edges} =
             CopyGraph.placed(scope, [story], ["bdd_specs_exist"])

    assert id == story.id
  end

  test "a file verdict's reason is the copy's, not a row's", %{scope: scope} do
    report =
      Map.update!(report(scope), "verdicts", fn verdicts ->
        Enum.map(verdicts, fn
          %{"name" => "technical_strategy"} = sweep ->
            %{sweep | "default" => false, "default_details" => %{"reason" => "from the overlay"}}

          sweep ->
            sweep
        end)
      end)

    {:ok, _} = CopyOverlay.report(scope, report)

    assert Requirements.open_reason(scope, "technical_strategy", [scope.active_project_id]) ==
             "from the overlay"
  end

  # What the copy's harness would report: its files, as scanned, against the
  # read model it was served.
  defp report(scope) do
    entries =
      Repo.all(from(f in FileRecord, where: f.working_copy_id == ^scope.active_working_copy_id))
      |> Enum.map(&Map.take(&1, [:path, :role, :valid, :validation_errors, :size]))

    {_read_model, payload} = CopyOverlay.served_read_model(scope)
    payload = payload |> Jason.encode!() |> Jason.decode!()

    read_model = %{
      Files.read_model(scope)
      | overlay_records: payload["overlay_records"],
        fingerprint: payload["fingerprint"]
    }

    %{
      "read_model" => read_model.fingerprint,
      "verdicts" => CopyOverlay.verdicts(entries, read_model)
    }
  end

  # The report with `technical_strategy` answered the other way.
  defp flipped(report) do
    Map.update!(report, "verdicts", fn verdicts ->
      Enum.map(verdicts, fn
        %{"name" => "technical_strategy"} = sweep -> %{sweep | "default" => not sweep["default"]}
        sweep -> sweep
      end)
    end)
  end

  defp node({nodes, _edges}, name), do: Enum.find(nodes, &(&1.name == name))

  defp behaviour(nodes),
    do: Map.new(nodes, &{Topology.node_key(&1), Verification.behavior(&1)})

  defp edges(edges), do: MapSet.new(edges, &{&1.from, &1.to})
end
