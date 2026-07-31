defmodule CodeMySpec.Repo.Migrations.CreateProjectDependencies do
  use Ecto.Migration

  # What a project depends on, recorded from its `mix.lock`.
  #
  # This exists to make hexdoc embedding a function of recorded state rather
  # than of catching a filesystem event at the right moment. The previous design
  # polled `mix.lock`'s mtime, then waited out a ten-second settle window for
  # `mix deps.get` to finish unpacking before globbing `deps/<pkg>/lib/**/*.ex`.
  # That is a race with a timer for a referee, and the kind that survives right
  # up until the machine is slower than the timer — at which point it projects a
  # half-unpacked tree and reports success.
  #
  # The lock is written before unpacking begins and is complete when it is
  # written, so it can be recorded immediately with no window to wait out.
  # Projection then becomes a convergence: work through the packages whose
  # recorded version has no docs projected yet, retrying the ones whose source
  # is not on disk yet. That has an observable end state, which the timer never
  # did — it can be asked for, retried, and verified.
  #
  # `projected_version` is the whole mechanism: a package needs projecting
  # exactly when it differs from `version`. NULL means never projected.
  def change do
    create table(:project_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :version, :string
      add :source, :string
      add :projected_version, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_dependencies, [:project_id, :name])

    # The projection pass asks "what still needs doing for this project?" on
    # every convergence tick, so it is worth not scanning the whole table.
    create index(:project_dependencies, [:project_id, :projected_version])
  end
end
