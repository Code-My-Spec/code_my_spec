defmodule CodeMySpec.Repo.Migrations.AddSetupOptionsToProjects do
  use Ecto.Migration

  # Mirror of the server migration. The CLI loads the same `Projects.Project`
  # schema, so a column the schema declares and cli.db lacks fails every
  # select against projects — not just the ones that read this field.
  def change do
    alter table(:projects) do
      add :setup_options, {:array, :string}
    end
  end
end
