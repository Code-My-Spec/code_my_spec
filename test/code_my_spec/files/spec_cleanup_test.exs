defmodule CodeMySpec.Files.SpecCleanupTest do
  @moduledoc """
  73e302aa. A criterion's wording is never changed (story 1076), so retiring it
  is the only change that invalidates its spex. Retiring deletes the spex naming
  its number on the caller's working copy, a sweep deletes any spex there whose
  number is not a live criterion, and each is reported as deleted or pending
  (copy offline). Another copy's spex are left to it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
  import Ecto.Query, only: [from: 2]
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Files
  alias CodeMySpec.Files.SpecCleanup
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.WorkingCopies

  @online "/online/app"
  @offline "/offline/app"

  setup do
    scope = full_scope_fixture()

    {:ok, online} =
      WorkingCopies.issue(scope, nil, label: "online", device: device_fixture(scope))

    {:ok, online} = WorkingCopies.report_root(online, @online)

    {:ok, offline} =
      WorkingCopies.issue(scope, nil, label: "offline", device: device_fixture(scope))

    {:ok, offline} = WorkingCopies.report_root(offline, @offline)

    {:ok, env} = InMemoryExecutionContext.create([])
    :ok = ExecutionContexts.register({:working_copy, online.id}, env)

    story = story_fixture(scope)
    one = criterion_fixture(scope, story, %{description: "A thing happens"})
    two = criterion_fixture(scope, story, %{description: "Another thing happens"})

    %{
      scope: %{scope | active_working_copy_id: online.id},
      env: env,
      online: online,
      offline: offline,
      story: story,
      one: one,
      two: two
    }
  end

  # Only the reachable copy has a disk to write to.
  defp write_on(%{online: %{id: id}} = ctx, %{id: id}, path),
    do: :ok = ExecutionContexts.write_file(ctx.env, path, "x")

  defp write_on(_ctx, _copy, _path), do: :ok

  defp spex(ctx, copy, path, number) do
    write_on(ctx, copy, path)

    {_n, _} =
      Files.upsert_files(%{ctx.scope | active_working_copy_id: copy.id}, [
        %{
          path: path,
          role: :bdd_spec,
          story_id: ctx.story.id,
          valid: true,
          mtime: DateTime.utc_now(),
          criterion_number: number
        }
      ])

    path
  end

  # Every recorded spex of the project, whichever copy it was seen on.
  defp rows(ctx) do
    CodeMySpec.Repo.all(
      from f in CodeMySpec.Files.File,
        where: f.project_id == ^ctx.scope.active_project_id and f.role == :bdd_spec,
        select: {f.path, f.criterion_number}
    )
    |> Map.new()
  end

  test "retiring a criterion deletes its spex, reports it, and leaves the others", ctx do
    mine = spex(ctx, ctx.online, "test/spex/s/criterion_one_spex.exs", ctx.one.number)
    other = spex(ctx, ctx.online, "test/spex/s/criterion_two_spex.exs", ctx.two.number)

    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    assert [%{path: ^mine, outcome: :deleted}] =
             SpecCleanup.for_retired(ctx.scope, ctx.one.number)

    refute ExecutionContexts.file_exists?(ctx.env, mine)
    assert ExecutionContexts.file_exists?(ctx.env, other)
    refute Map.has_key?(rows(ctx), mine)
    assert Map.has_key?(rows(ctx), other)
  end

  test "a spex on a copy that cannot be reached is pending, kept, and covers nothing", ctx do
    path = spex(ctx, ctx.offline, "test/spex/s/criterion_one_spex.exs", ctx.one.number)

    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    on_offline = %{ctx.scope | active_working_copy_id: ctx.offline.id}

    assert [%{path: ^path, outcome: {:pending, _why}}] =
             SpecCleanup.for_retired(on_offline, ctx.one.number)

    assert Map.has_key?(rows(ctx), path)

    assert SpecCleanup.report(SpecCleanup.for_retired(on_offline, ctx.one.number)) =~
             "Pending deletion: #{path}"
  end

  test "another copy's spex is left for that copy to remove", ctx do
    theirs = spex(ctx, ctx.offline, "test/spex/s/criterion_one_spex.exs", ctx.one.number)

    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    assert SpecCleanup.for_retired(ctx.scope, ctx.one.number) == []
    assert SpecCleanup.sweep_orphans(ctx.scope) == []
    assert Map.has_key?(rows(ctx), theirs)
  end

  test "the sweep deletes a spex naming a retired or unknown number, and only those", ctx do
    retired = spex(ctx, ctx.online, "test/spex/s/retired_spex.exs", ctx.one.number)
    unknown = spex(ctx, ctx.online, "test/spex/s/unknown_spex.exs", 999_999)
    live = spex(ctx, ctx.online, "test/spex/s/live_spex.exs", ctx.two.number)
    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    results = SpecCleanup.sweep_orphans(ctx.scope)

    assert Enum.sort(Enum.map(results, & &1.path)) == Enum.sort([retired, unknown])
    assert Enum.all?(results, &(&1.outcome == :deleted))
    assert ExecutionContexts.file_exists?(ctx.env, live)
    refute ExecutionContexts.file_exists?(ctx.env, retired)
  end

  test "with nothing to remove the report says so, and the sweep is idempotent", ctx do
    assert SpecCleanup.sweep_orphans(ctx.scope) == []
    assert SpecCleanup.report([]) == "No spex file named it."
  end

  test "a live criterion's spex is never touched", ctx do
    live = spex(ctx, ctx.online, "test/spex/s/live_spex.exs", ctx.two.number)

    assert SpecCleanup.sweep_orphans(ctx.scope) == []
    assert ExecutionContexts.file_exists?(ctx.env, live)
  end
end
