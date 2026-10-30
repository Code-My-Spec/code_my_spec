defmodule CodeMySpec.Requirements.ACopyOverlayAgreesWithTheServersRowsTest do
  @moduledoc """
  A harness's file verdicts, from its own scan and the records it was handed,
  are the verdicts the server stores for its checkout.

  The harness has no database: it settles the eight file requirements from its
  scan entries and the read model, records included, as they cross the wire.
  Stored as the copy's overlay, they are compared with the server's rows for
  the checkout, and a verdict that differs is counted.
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
  alias CodeMySpec.Requirements.{CopyOverlay, IncrementalGraph}
  alias CodeMySpec.Requirements.CopyOverlay.Report
  alias CodeMySpecTest.WithoutDatabase

  setup do
    scope = full_scope_fixture()
    context = component_fixture(scope, %{type: "context", module_name: "MyApp.Billing"})
    story = story_fixture(scope, %{ready_for_dev: true})
    first = criterion_fixture(scope, story)
    criterion_fixture(scope, story)

    # Owners and criterion numbers as the server resolves them at sync.
    for {path, role, errors, component_id, criterion} <- [
          {"lib/my_app/billing.ex", :implementation, nil, context.id, nil},
          {Paths.decisions_index(), :architecture, nil, nil, nil},
          {"test/spex/#{story.number}_billing/criterion_#{first.number}_spex.exs", :bdd_spec,
           %{"data" => %{"criterion" => first.number}}, nil, first.number},
          {Paths.proposal_path(), :architecture,
           %{"data" => %{"story_numbers" => [story.number, 9_999], "context_names" => []}}, nil,
           nil}
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

    %{scope: scope, context: context}
  end

  test "the harness's verdicts, with no database, agree with every stored row", %{scope: scope} do
    {entries, read_model} = as_the_harness_holds_them(scope)

    {:ok, verdicts} = WithoutDatabase.run(fn -> CopyOverlay.verdicts(entries, read_model) end)
    assert {:ok, _} = CopyOverlay.report(scope, report(verdicts))

    assert {:ok, %{compared: compared, mismatches: []}} = CopyOverlay.check(scope)
    assert compared >= 8, "the premise did not hold: #{compared} rows compared"

    assert %Report{mismatches: 0, clean_reports: 1} =
             Repo.get(Report, scope.active_working_copy_id)
  end

  test "a verdict that differs from the stored row is counted, and breaks the clean run",
       %{scope: scope} do
    {entries, read_model} = as_the_harness_holds_them(scope)
    verdicts = CopyOverlay.verdicts(entries, read_model)

    {:ok, _} = CopyOverlay.report(scope, report(verdicts))
    {:ok, %{mismatches: []}} = CopyOverlay.check(scope)

    flipped =
      Enum.map(verdicts, fn
        %{"name" => "technical_strategy"} = sweep -> %{sweep | "default" => not sweep["default"]}
        sweep -> sweep
      end)

    {:ok, _} = CopyOverlay.report(scope, report(flipped))

    assert {:ok, %{mismatches: [%{name: "technical_strategy"}]}} = CopyOverlay.check(scope)

    assert %Report{mismatches: 1, clean_reports: 0} =
             Repo.get(Report, scope.active_working_copy_id)
  end

  # Scan entries carry no owner and no criterion number until the server
  # resolves them; the records arrive as JSON.
  defp as_the_harness_holds_them(scope) do
    entries =
      Repo.all(from(f in FileRecord, where: f.working_copy_id == ^scope.active_working_copy_id))
      |> Enum.map(
        &%{
          path: &1.path,
          role: &1.role,
          valid: &1.valid,
          validation_errors: &1.validation_errors,
          mtime: nil,
          size: nil,
          fingerprint: nil
        }
      )

    records = scope |> CopyOverlay.records() |> Jason.encode!() |> Jason.decode!()
    {entries, %{Files.read_model(scope) | overlay_records: records}}
  end

  defp report(verdicts),
    do: %{
      "read_model" => "test",
      "head" => nil,
      "behind" => nil,
      "dirty" => nil,
      "verdicts" => verdicts
    }
end
