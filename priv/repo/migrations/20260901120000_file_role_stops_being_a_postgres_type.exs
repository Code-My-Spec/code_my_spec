defmodule CodeMySpec.Repo.Migrations.FileRoleStopsBeingAPostgresType do
  @moduledoc """
  `files.role` becomes a string, validated where it was already being validated.

  It was a native `file_role` enum, so every new role needed its own migration
  carrying `@disable_ddl_transaction` and `@disable_migration_lock` — and the
  value could not be *used* in the pass that added it, because Postgres does not
  publish an enum label until the adding transaction commits. So each one cost a
  migration plus a follow-up deploy to use it.

  Fifteen migrations in this directory exist for no other reason.

  Nothing is lost by dropping it. `Files.File` already declares
  `field :role, Ecto.Enum, values: @roles`, so an unknown role is refused at the
  changeset either way; the database type was a second copy of that list, kept in
  step by hand, and the two had already drifted — the type carries `issue`, which
  the schema dropped. No row uses it, checked before writing this.

  Issue 42b32a6e.
  """

  use Ecto.Migration

  # The labels as they stood, so `down` restores what was here rather than what
  # the schema happens to say today. `issue` is included for that reason: it is
  # in the type being dropped.
  @labels ~w(
    spec implementation test rule json review bdd_spec qa_brief qa_result config
    architecture integration issue task_artifact mix_exs credo_exs claude_md
    setup_config test_support agents_md knowledge project_knowledge hex_doc
    persona_summary persona_sources credo_check qa_plan qa_script deploy_artifact
    encrypted_env
  )

  def up do
    execute("ALTER TABLE files ALTER COLUMN role TYPE varchar(255) USING role::text")
    execute("DROP TYPE file_role")
  end

  def down do
    values = Enum.map_join(@labels, ", ", &"'#{&1}'")

    execute("CREATE TYPE file_role AS ENUM (#{values})")

    # A row whose role is not one of the labels above cannot go back into the
    # type. There are none today; if a new role has been added since, this fails
    # loudly here rather than silently dropping the rows that carry it.
    execute("ALTER TABLE files ALTER COLUMN role TYPE file_role USING role::file_role")
  end
end
