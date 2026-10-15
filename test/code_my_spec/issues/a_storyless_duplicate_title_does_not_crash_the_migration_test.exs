defmodule CodeMySpec.Issues.AStorylessDuplicateTitleDoesNotCrashTheMigrationTest do
  @moduledoc """
  Issue b4b2266c: migration 20261014120000 (`issues_title_project_id_no_story_index`,
  the fix for b2752ae3) created its unique index with no deduplication step
  first. Any database already carrying two or more storyless issues that
  share a title and project -- coincidence, unrelated to any fault -- failed
  the index creation outright and crashed app startup. Two `dismissed` rows
  titled "test", five months old, did exactly this on a real copy's dev
  database.

  The migration now renames every row after the oldest in each
  (title, project_id) group before creating the index, preserving every
  record rather than deleting any of them.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @version 20_261_014_120_000
  @migration "priv/repo/migrations/20261014120000_a_storyless_issue_title_is_unique_per_project.exs"

  defp legacy_storyless_issue(scope, title, offset_seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%Issue{
      title: title,
      severity: :high,
      scope: :app,
      description: "a legacy row from before this guard existed",
      status: :dismissed,
      story_id: nil,
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      inserted_at: DateTime.add(now, offset_seconds, :second),
      updated_at: now
    })
  end

  test "two pre-existing storyless issues sharing a title do not block the index, and both survive" do
    scope = full_scope_fixture()

    older = legacy_storyless_issue(scope, "test", -100)
    newer = legacy_storyless_issue(scope, "test", 0)

    Sandbox.mode(Repo, {:shared, self()})
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])

    # Drop the index this migration creates, since it already exists on this
    # database from an earlier run -- re-running the migration body itself,
    # including the dedup, is what is under test.
    Repo.query!("DROP INDEX IF EXISTS issues_title_project_id_no_story_index")

    [{module, _}] = Code.require_file(@migration)

    assert :ok = Ecto.Migrator.up(Repo, @version, module, log: false, migration_lock: false),
           "the migration crashed on pre-existing duplicate data instead of deduping first"

    reloaded_older = Repo.get!(Issue, older.id)
    reloaded_newer = Repo.get!(Issue, newer.id)

    assert reloaded_older.title == "test", "the oldest row's title should be left alone"

    refute reloaded_newer.title == "test",
           "the newer duplicate was not renamed, so the index should not have been creatable"

    assert reloaded_newer.title =~ newer.id,
           "the renamed row should still be traceable to its own id, not just altered"

    # The index now exists and genuinely enforces uniqueness going forward.
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Issue{
        title: "test",
        severity: :high,
        scope: :framework,
        description: "a fresh duplicate, after the fix",
        story_id: nil,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id
      })
    end
  end
end
