defmodule CodeMySpec.Repo.Migrations.AddPersonaTypeToPersonas do
  use Ecto.Migration

  def change do
    alter table(:personas) do
      add :persona_type, :string, default: "proto"
    end
  end
end
