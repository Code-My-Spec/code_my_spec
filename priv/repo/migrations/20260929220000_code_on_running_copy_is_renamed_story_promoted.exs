defmodule CodeMySpec.Repo.Migrations.CodeOnRunningCopyIsRenamedStoryPromoted do
  use Ecto.Migration

  # f4786ba1: the requirement is named for what it reads — a story's
  # `promoted_version` stamp — rather than a git fact. Stored rows carry the
  # name (unique on `{owner}_id, name, working_copy_id`, and no row holds the
  # new name yet), as do agents' and sessions' embedded task lists.
  def up, do: rename_requirement("code_on_running_copy", "story_promoted")

  def down, do: rename_requirement("story_promoted", "code_on_running_copy")

  defp rename_requirement(from, to) do
    for table <- ~w(requirements shadow_requirements) do
      execute("UPDATE #{table} SET name = '#{to}' WHERE name = '#{from}'")
    end

    for table <- ~w(agents sessions) do
      execute("""
      UPDATE #{table}
      SET tasks = replace(tasks::text, '\\"#{from}\\"', '\\"#{to}\\"')::jsonb[]
      WHERE tasks::text LIKE '%#{from}%'
      """)
    end
  end
end
