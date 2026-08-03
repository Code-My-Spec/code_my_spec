defmodule CodeMySpec.Repo.Migrations.CreateIntakePlans do
  use Ecto.Migration

  # A plan is what an anonymous visitor has before they have an account. It is
  # a row rather than a session because the whole point is that it survives
  # leaving — the visitor is asked for an email only once something specific to
  # them exists to lose.
  #
  # `session_token` is the anonymous cookie value and the only way back to a
  # plan before signup. A different browser therefore finds nothing, which is a
  # designed outcome rather than a failure: the visitor gets a fresh start.
  #
  # Plans are never reaped. There is no expiry column because there is no
  # expiry — an abandoned plan costs one row, and reaping it would trade that
  # for a promise we would have to qualify.
  def change do
    create table(:intake_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_token, :string, null: false

      add :status, :string, null: false

      # What the visitor typed, in their own words.
      add :description, :text

      # The two generator inputs, asked in operator language. Null means
      # unanswered — distinct from a deliberate `false`, which is why these
      # carry no migration-level default.
      add :needs_sign_in, :boolean
      add :separate_copies, :boolean
      add :who_uses, :string

      # The plan itself, in the visitor's terms. This is the artifact that
      # earns the email.
      add :summary, :text
      add :first_build, :text

      # Proposed by the plan, then overwritten in place by any correction the
      # visitor makes. Nothing keeps the superseded proposal — what gets
      # created must be what was confirmed.
      add :account_name, :string
      add :project_name, :string

      # Filled at the gate. Their presence is what makes a plan converted, and
      # what stops a second visit creating a second account.
      add :account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:intake_plans, [:session_token])
  end
end
