defmodule CodeMySpec.Requirements.AProjectorArrivingEstablishesWhatIsTrueTest do
  @moduledoc """
  A projector that has just started computes the graph, rather than waiting for
  something to happen.

  `init/1` says why, and says it as a rule: "an accumulated projection has to
  start from a known state, and a consumer that only ever applied deltas would
  hold a shadow that is missing every entity nothing has touched since it
  started, permanently, while reporting the gap as a coverage failure it cannot
  fix."

  ## How the seed stopped seeding

  Two changes, each reasonable on its own, each removing half of it:

    * `vantages/2` began deriving the checkouts to settle from the marks in
      hand. A seed has no marks, so it derived none, and the whole-project
      computation ran against an empty list of vantages.
    * `settle_vantage/6` skipped the plan when no mark was left unhandled.
      "Nothing left to re-derive" and "nothing arrived" are not the same
      statement, and the seed is the second one.

  `plan/2` kept its `seeded: false` clause answering `:everything` the whole
  time. Nothing called it.

  ## Measured

  On dev, 2026-09-17: nine verdicts stood wrong at three vantages, each last
  settled before a fix that would have corrected it, and each survived four
  restarts of the process whose arrival was supposed to correct it.
  """
  use CodeMySpecSpex.Case

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.ShadowProjector
  alias CodeMySpec.StoriesFixtures
  alias CodeMySpec.Users.Scope
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    on_exit(fn -> Application.delete_env(:code_my_spec, :graph_shadow_projection) end)
    :ok
  end

  describe "a projector starting on a project that already has a graph" do
    test "corrects a verdict stored wrong at a checkout nothing has touched",
         %{scope: %Scope{} = project_scope} do
      mine = %{project_scope | active_working_copy_id: nil}
      other = Fixtures.live_agent_scope(project_scope, label: "a quiet checkout")

      StoriesFixtures.story_fixture(mine)
      CodeMySpec.Requirements.recompute(mine)
      CodeMySpec.Requirements.recompute(other)
      {:ok, _pid} = ShadowProjector.ensure_projecting(mine)
      :ok = ShadowProjector.settle(mine.active_project_id)

      name = flip_one_verdict(other)

      restart_projector(mine)

      assert disagreements(other) == [],
             """
             A verdict stored wrong at another checkout survived the restart.

             The seed asks what is true, and a verdict is a statement about a
             checkout — so it has to ask at every checkout that has rows, not
             only at the one whose scope happened to start the process. A quiet
             worktree is exactly where a wrong answer lasts: nothing is arriving
             there to settle it.

             still wrong: #{inspect(disagreements(other))} (flipped: #{name})
             """
    end

    test "corrects a verdict that was already stored wrong", %{scope: %Scope{} = project_scope} do
      scope = %{project_scope | active_working_copy_id: nil}

      StoriesFixtures.story_fixture(scope)
      CodeMySpec.Requirements.recompute(scope)
      {:ok, _pid} = ShadowProjector.ensure_projecting(scope)
      :ok = ShadowProjector.settle(scope.active_project_id)

      # A row standing at the wrong answer, which is what a projection carries
      # after a bug is fixed: nothing is coming to correct it, because the
      # correction was to the code and not to the project.
      name = flip_one_verdict(scope)

      # The projector arrives again, as it does on every restart of the
      # application. Seeding is the only thing that repairs this — the marks say
      # nothing has moved, because nothing has.
      restart_projector(scope)

      assert disagreements(scope) == [],
             """
             A verdict stored wrong survived the projector restarting.

             A restart is the one moment the projection can be brought back in
             line with what a recompute says, and it is the repair every fix to
             a handler depends on. Without it a wrong answer outlives the bug
             that wrote it, for the life of the project.

             still wrong: #{inspect(disagreements(scope))} (flipped: #{name})
             """
    end
  end

  defp restart_projector(%Scope{} = scope) do
    pid = GenServer.whereis(ShadowProjector.via(scope.active_project_id))
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    {:ok, _pid} = ShadowProjector.ensure_projecting(scope)
    :ok = ShadowProjector.settle(scope.active_project_id)
  end

  # Store the opposite of what the graph says, for one row at this scope's
  # vantage, and answer which. `IS NOT DISTINCT FROM` because the vantage is
  # nullable and the null means something — the row-space a reader with no
  # checkout is answered from — and `=` against it matches nothing.
  defp flip_one_verdict(%Scope{} = scope) do
    [{id, name, satisfied}] =
      scope |> at_vantage("shadow_requirements") |> Ecto.Query.limit(1) |> Repo.all()

    {1, _} =
      from(n in "shadow_requirements", where: n.id == ^id)
      |> Repo.update_all(set: [satisfied: not satisfied])

    name
  end

  defp disagreements(%Scope{} = scope) do
    stored = scope |> at_vantage("shadow_requirements") |> Repo.all() |> Map.new(&key/1)
    computed = scope |> at_vantage("requirements") |> Repo.all() |> Map.new(&key/1)

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
