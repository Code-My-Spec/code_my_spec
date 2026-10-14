defmodule CodeMySpec.Repo.Migrations.TheStorylessIssueIndexExcludesOnlyResolved do
  use Ecto.Migration

  @moduledoc """
  The index added in 20261014120000 (`issues_title_project_id_no_story_index`)
  enforced uniqueness among *every* storyless issue with a given title and
  project, regardless of status -- but `Issues.open_issue_titled?/2`, the
  application check it is supposed to back up, excludes only `:resolved`
  (a dismissed fault stays suppressed; a resolved one recurring is a
  regression and is meant to file a fresh issue). The broader index silently
  refused that second, legitimate issue as a duplicate
  (test/code_my_spec/main_agent/a_fault_is_raised_once_test.exs, "but a
  resolved fault coming back is a regression and is heard again").

  Recreated with the same name and the same `status <> 'resolved'` exclusion
  as the application check, so the two agree.
  """

  def change do
    drop(index(:issues, [:title, :project_id], name: :issues_title_project_id_no_story_index))

    create(
      unique_index(:issues, [:title, :project_id],
        name: :issues_title_project_id_no_story_index,
        where: "story_id IS NULL AND status <> 'resolved'"
      )
    )
  end
end
