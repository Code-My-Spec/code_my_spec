defmodule CodeMySpec.Files.SpecCleanupTest do
  @moduledoc """
  A criterion's wording is never changed (story 1076), so retiring it is the
  only change that invalidates its spex. Retiring never deletes a file
  (dea00db7: deleted in the product agent's checkout, main's, they refused
  every sync after them). The spex on the caller's copy that cover nothing are
  listed for the agent to remove in its own copy; another copy's are not.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
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

  test "retiring a criterion lists its spex for removal and deletes nothing", ctx do
    mine = spex(ctx, ctx.online, "test/spex/s/criterion_one_spex.exs", ctx.one.number)
    other = spex(ctx, ctx.online, "test/spex/s/criterion_two_spex.exs", ctx.two.number)

    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    one = ctx.one.number
    assert [%{path: ^mine, criterion_number: ^one}] = SpecCleanup.orphans(ctx.scope)
    assert ExecutionContexts.file_exists?(ctx.env, mine)
    assert ExecutionContexts.file_exists?(ctx.env, other)
  end

  test "the list names a spex for a retired or unknown number, and only those", ctx do
    retired = spex(ctx, ctx.online, "test/spex/s/retired_spex.exs", ctx.one.number)
    unknown = spex(ctx, ctx.online, "test/spex/s/unknown_spex.exs", 999_999)
    _live = spex(ctx, ctx.online, "test/spex/s/live_spex.exs", ctx.two.number)
    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    paths = ctx.scope |> SpecCleanup.orphans() |> Enum.map(& &1.path) |> Enum.sort()
    assert paths == Enum.sort([retired, unknown])
  end

  test "another copy's spex is left for that copy", ctx do
    spex(ctx, ctx.offline, "test/spex/s/criterion_one_spex.exs", ctx.one.number)
    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    assert SpecCleanup.orphans(ctx.scope) == []
  end

  test "the report tells the agent to delete each in its copy and commit", ctx do
    path = spex(ctx, ctx.online, "test/spex/s/criterion_one_spex.exs", ctx.one.number)
    {:ok, _} = AcceptanceCriteria.retire_criterion(ctx.scope, ctx.one)

    report = ctx.scope |> SpecCleanup.orphans() |> SpecCleanup.report()
    assert report =~ "- #{path} (criterion #{ctx.one.number})"
    assert report =~ "Delete each in your working copy and commit"
    assert SpecCleanup.report([]) =~ "No spex on your working copy"
  end
end
