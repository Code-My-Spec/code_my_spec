defmodule CodeMySpec.Requirements.ADormantCheckoutIsSettledWholeWhenItWakesTest do
  @moduledoc """
  A checkout no harness serves is left alone while it sleeps, and settled whole
  when it wakes.

  A change about no checkout fans out to every vantage. Most checkouts of a
  large project are old worktrees nobody opens, and settling them on every
  issue and story event was most of what those drains cost. A dormant one is
  passed by and left one durable mark; when it is seen again, the next drain
  seeds it, so it ends where a full recompute would.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{GraphInputs, IncrementalGraph, Invalidation, Preloader}
  alias CodeMySpec.Requirements.{Projection, RequirementGraph}
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  test "a dormant checkout keeps its rows through a change, then wakes to a full recompute's" do
    here = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(here, nil, label: "Asleep", device: device_fixture(here))
    asleep = %{here | active_working_copy_id: copy.id}
    story_fixture(here, %{ready_for_dev: true})

    {:ok, _pid} = IncrementalGraph.ensure_projecting(here)
    :ok = IncrementalGraph.settle(here.active_project_id, [here.active_working_copy_id, copy.id])
    assert resolved?(asleep), "the premise did not hold: nothing was unresolved to begin with"

    two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86_400)

    Repo.update_all(from(w in WorkingCopy, where: w.id == ^copy.id),
      set: [last_seen_at: two_days_ago]
    )

    # Moves `issues_resolved` at every checkout: a per-checkout verdict.
    {:ok, issue} =
      Issues.create_issue(here, %{title: "Unresolved", description: "blocking", severity: :high})

    {:ok, _} = Issues.accept_issue(here, issue)
    :ok = IncrementalGraph.settle(here.active_project_id)

    refute resolved?(here), "the awake checkout should have settled the accepted issue"
    assert resolved?(asleep), "the dormant checkout was settled while asleep"
    assert waiting_mark?(copy.id), "nothing was left to settle the dormant checkout when it wakes"

    # Woken: seen again, and its harness rescans.
    WorkingCopies.mark_alive(copy.id)
    GraphInputs.event(asleep, "Test", "files_synced", %{}, [], :this_checkout)
    :ok = IncrementalGraph.settle(here.active_project_id, [copy.id])

    refute waiting_mark?(copy.id)
    assert served(asleep) == recomputed(asleep)
  end

  defp resolved?(scope) do
    {nodes, _edges} = Projection.load(scope, Preloader.read_context(scope))
    Enum.find(nodes, &(&1.name == "issues_resolved")).satisfied
  end

  defp waiting_mark?(copy_id) do
    Repo.exists?(
      from(i in Invalidation,
        where: i.working_copy_id == ^copy_id and i.entity_scope == "unknown"
      )
    )
  end

  defp served(scope) do
    {nodes, _edges} = Projection.load(scope, Preloader.read_context(scope))
    verdicts(nodes)
  end

  defp recomputed(scope) do
    {:ok, ctx} = Preloader.load(scope)
    {nodes, _} = RequirementGraph.compute_nodes(scope, ctx, Configurations.get_or_create(scope))
    verdicts(nodes)
  end

  defp verdicts(nodes) do
    Map.new(nodes, fn n ->
      {{n.entity_type, to_string(n.entity_id), n.name},
       {n.satisfied, (n.details || %{}) |> Jason.encode!() |> Jason.decode!()}}
    end)
  end
end
