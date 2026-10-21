defmodule CodeMySpec.Analysis.PromotionRetryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis

  @commit String.duplicate("a", 40)
  @other_commit String.duplicate("b", 40)
  @since ~U[2026-10-10 12:00:00Z]

  setup do
    %{scope: full_scope_fixture()}
  end

  defp failed_run(scope, at, attrs \\ %{}) do
    run = analysis_run_fixture(scope, %{source: "spex", kind: :full, status_override: :failed})

    run
    |> Ecto.Changeset.change(Map.merge(%{inserted_at: at, start_commit: @commit}, attrs))
    |> Repo.update!()
  end

  test "a previous promotion's failures do not spend the new attempt's retry budget", ctx do
    failed_run(ctx.scope, DateTime.add(@since, -60))
    failed_run(ctx.scope, DateTime.add(@since, -30))
    failed_run(ctx.scope, DateTime.add(@since, -1), %{start_commit: nil})

    assert Analysis.failed_at_commit(ctx.scope, "spex", @commit, @since) == 0

    failed_run(ctx.scope, @since)
    assert Analysis.failed_at_commit(ctx.scope, "spex", @commit, @since) == 1
  end

  test "current-attempt failures count at the commit or before the harness reports a commit",
       ctx do
    failed_run(ctx.scope, @since)
    failed_run(ctx.scope, DateTime.add(@since, 1), %{start_commit: nil})

    assert Analysis.failed_at_commit(ctx.scope, "spex", @commit, @since) == 2
  end

  test "other commits, orphaned failures and unrelated runs do not consume retries", ctx do
    failed_run(ctx.scope, @since, %{start_commit: @other_commit})
    failed_run(ctx.scope, @since, %{orphaned: true})
    failed_run(ctx.scope, @since, %{start_commit: nil, orphaned: true})
    failed_run(ctx.scope, @since, %{kind: :partial})
    failed_run(ctx.scope, @since, %{source: "exunit"})
    failed_run(ctx.scope, @since, %{status: :completed})
    failed_run(full_scope_fixture(), @since)

    assert Analysis.failed_at_commit(ctx.scope, "spex", @commit, @since) == 0
  end
end
