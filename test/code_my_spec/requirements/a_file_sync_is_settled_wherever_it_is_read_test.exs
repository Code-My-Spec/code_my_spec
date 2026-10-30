defmodule CodeMySpec.Requirements.AFileSyncIsSettledWhereverItIsReadTest do
  @moduledoc """
  A checkout's file sync is settled at every vantage that reads its files, and
  the project-wide requirements it moves are settled once, wherever it is first
  seen.

  Each vantage settles only the marks about it, and a project-wide requirement
  is the same everywhere, so it is settled once per drain. Two ways that lost a
  sync: `nil` reads every checkout's files when the project has no default
  checkout, but was handed only the default's marks; and a project-wide
  requirement was skipped at every vantage after the first, though the first
  had not seen the sync that moved it — `personas_complete` stayed stale and
  gated triage behind it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Issues
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Qa.Documents
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{GraphInputs, IncrementalGraph, Preloader, Projection}
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecTest.SuspendedProjector

  @qa_plan """
  # QA plan

  ## App Overview

  The app.

  ## Tools Registry

  A browser.

  ## Seed Strategy

  Fixtures.
  """

  test "with no default checkout, a sync at any checkout moves what nil reads" do
    scope = full_scope_fixture()
    nil_scope = %{scope | active_working_copy_id: nil}
    no_default(scope)

    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])
    refute satisfied?(nil_scope, "technical_strategy"), "the premise did not hold"

    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: Paths.decisions_index(),
      role: :architecture,
      valid: true
    })

    GraphInputs.event(scope, "Test", "files_synced", %{}, [], :this_checkout)
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])

    assert satisfied?(nil_scope, "technical_strategy"),
           "nil reads every checkout's files, yet a checkout's sync did not reach it"
  end

  test "a project-wide requirement a sync moves is settled though nil saw only another event" do
    here = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(here, nil, label: "Other", device: device_fixture(here))
    other = %{here | active_working_copy_id: copy.id}
    awake([here.active_working_copy_id, copy.id])

    Repo.update_all(from(p in Project, where: p.id == ^here.active_project_id),
      set: [default_working_copy_id: here.active_working_copy_id]
    )

    {:ok, pid} = IncrementalGraph.ensure_projecting(here)
    :ok = IncrementalGraph.settle(here.active_project_id, [here.active_working_copy_id, copy.id])
    refute satisfied?(other, "qa_setup"), "the premise did not hold"

    # One drain: an event about no checkout, which `nil` settles first, and a
    # sync at the checkout that is not the default.
    SuspendedProjector.while_suspended(pid, fn ->
      {:ok, _} = Documents.put(here, "qa_plan", nil, @qa_plan)

      {:ok, _} =
        Issues.create_issue(here, %{title: "Probe", description: "probe", severity: :low})

      GraphInputs.event(other, "Test", "files_synced", %{}, [], :this_checkout)
    end)

    :ok = IncrementalGraph.settle(here.active_project_id, [copy.id])

    assert satisfied?(other, "qa_setup"),
           "the sync moved qa_setup, but it was skipped after nil, which never saw the sync"
  end

  defp satisfied?(scope, name) do
    {nodes, _edges} = Projection.load(scope, Preloader.read_context(scope))
    Enum.find(nodes, &(&1.name == name)).satisfied
  end

  defp no_default(scope) do
    Repo.update_all(from(p in Project, where: p.id == ^scope.active_project_id),
      set: [default_working_copy_id: nil]
    )

    Repo.update_all(from(w in WorkingCopy, where: w.project_id == ^scope.active_project_id),
      set: [main: false]
    )
  end

  defp awake(copy_ids),
    do:
      Repo.update_all(from(w in WorkingCopy, where: w.id in ^copy_ids),
        set: [last_seen_at: DateTime.utc_now()]
      )
end
