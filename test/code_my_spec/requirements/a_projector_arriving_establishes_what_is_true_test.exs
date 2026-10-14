defmodule CodeMySpec.Requirements.AProjectorArrivingEstablishesWhatIsTrueTest do
  @moduledoc """
  A projector that has just started trusts the rows it finds and seeds the
  vantages that have none.

  The rows are durable and the mark queue is durable, so everything that
  happened while the process was down is still queued and applied by the first
  drain; the files, the one input with no row of its own, are rescanned by the
  harness when it reconnects and arrive as `files_synced`. A vantage with no
  rows is the one case a delta has nothing to be relative to, and it is seeded
  whole.

  ## What this replaced, and why

  Every arrival used to recompute every vantage — "an accumulated projection
  has to start from a known state". Measured on the big project, 2026-09-21:
  10.3s at every restart and every promote, recomputing rows the diff had just
  agreed with. John: "we can trust our domain". The old test asserted that an
  arrival corrects a verdict stored wrong; under this contract a wrong row is
  corrected by the next observation about its entity, which is the third case
  below — and a row nothing observes stays as it is, which is the same trust
  the pass places in its stored rows.
  """
  use CodeMySpecSpex.Case, async: true
  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.StoriesFixtures
  alias CodeMySpec.Users.Scope
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok
  end

  describe "a projector starting on a project that already has a graph" do
    test "leaves the rows it finds as they are", %{scope: %Scope{} = project_scope} do
      scope = %{project_scope | active_working_copy_id: nil}
      StoriesFixtures.story_fixture(scope)
      CodeMySpec.Requirements.recompute(scope)
      {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
      :ok = IncrementalGraph.settle(scope.active_project_id)

      # A row standing at the wrong answer, with nothing coming to correct it.
      name = flip_one_verdict(scope)
      restart_projector(scope)

      assert Enum.any?(disagreements(scope), &match?({^name, _live, _shadow}, &1)),
             """
             A projector arriving rewrote a row it found.

             The rows are durable and the marks are durable; an arrival that
             recomputes what is already there costs a whole graph per vantage
             on every restart and every promote — 10.3s on the big project —
             to rewrite rows the diff had just agreed with.

             disagreements: #{inspect(disagreements(scope))} (flipped: #{name})
             """
    end

    test "seeds a checkout that has no rows", %{scope: %Scope{} = project_scope} do
      mine = %{project_scope | active_working_copy_id: nil}
      other = Fixtures.live_agent_scope(project_scope, label: "a checkout nobody has projected")
      StoriesFixtures.story_fixture(mine)
      CodeMySpec.Requirements.recompute(mine)
      CodeMySpec.Requirements.recompute(other)
      {:ok, _pid} = IncrementalGraph.ensure_projecting(mine)
      :ok = IncrementalGraph.settle(mine.active_project_id)

      assert disagreements(other) == [],
             """
             A checkout with no rows of its own was not seeded when the
             projector arrived and settled.

             A vantage with no rows has nothing for a delta to be relative to;
             it is the one case an arrival computes whole.

             disagreements: #{inspect(disagreements(other))}
             """
    end

    test "corrects a wrong row on the next observation about its entity",
         %{scope: %Scope{} = project_scope} do
      scope = %{project_scope | active_working_copy_id: nil}
      story = StoriesFixtures.story_fixture(scope)
      CodeMySpec.Requirements.recompute(scope)
      {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
      :ok = IncrementalGraph.settle(scope.active_project_id)

      name = flip_one_verdict(scope)
      restart_projector(scope)

      # An observation about the story. `story_changed` is handled: the
      # handler settles every requirement its profiles move from what is true
      # now, which is what puts the flipped row back.
      {:ok, _story} = CodeMySpec.Stories.update_story(scope, story, %{description: "moved"})
      :ok = IncrementalGraph.settle(scope.active_project_id)

      refute Enum.any?(disagreements(scope), &match?({^name, _live, _shadow}, &1)),
             """
             An observation about the story arrived and the row stored wrong
             for it was not corrected.

             Trusting rows on arrival is only right because the next
             observation about an entity settles its rows from what is true
             now; a handler that settles from the stored answer rather than
             the world would make the trust permanent.

             still wrong: #{inspect(disagreements(scope))} (flipped: #{name})
             """
    end
  end

  # Through the supervisor, not `Process.exit(pid, :kill)`. The child is
  # `restart: :transient`, so an abnormal exit is one the supervisor puts back
  # itself — and then `ensure_projecting/1` is racing that restart for the same
  # registered name, which is a start_child call that can block rather than a
  # projector arriving. Terminating is how a projector goes away for good.
  defp restart_projector(%Scope{} = scope) do
    pid = GenServer.whereis(IncrementalGraph.via(scope.active_project_id))
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    {:ok, fresh} = IncrementalGraph.ensure_projecting(scope)
    refute fresh == pid, "the projector did not go away, so nothing arrived"
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  # Store the opposite of what the graph says, for one row at this scope's
  # vantage, and answer which. `IS NOT DISTINCT FROM` because the vantage is
  # nullable and the null means something — the row-space a reader with no
  # checkout is answered from — and `=` against it matches nothing.
  defp flip_one_verdict(%Scope{} = scope) do
    [{id, name, satisfied}] =
      scope |> at_vantage("requirements") |> Ecto.Query.limit(1) |> Repo.all()

    {1, _} =
      from(n in "requirements", where: n.id == ^id)
      |> Repo.update_all(set: [satisfied: not satisfied])

    name
  end

  defp disagreements(%Scope{} = scope) do
    stored = scope |> at_vantage("requirements") |> Repo.all() |> Map.new(&key/1)
    # What the domain says now, computed in memory.
    {nodes, _edges} = RequirementGraph.compute_graph(scope)

    computed =
      nodes |> Enum.filter(&(&1.entity_type == "story")) |> Map.new(&{&1.name, &1.satisfied})

    for {k, v} <- stored, Map.has_key?(computed, k), computed[k] != v, do: {k, v, computed[k]}
  end

  defp key({_id, name, satisfied}), do: {name, satisfied}

  defp at_vantage(%Scope{} = scope, table) do
    copy = scope.active_working_copy_id

    from(n in table,
      join: s in "stories",
      on: s.id == n.story_id,
      where: s.project_id == type(^scope.active_project_id, :binary_id),
      where: fragment("? IS NOT DISTINCT FROM ?", n.working_copy_id, type(^copy, :binary_id)),
      order_by: [asc: n.id],
      select: {n.id, n.name, n.satisfied}
    )
  end
end
