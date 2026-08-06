defmodule CodeMySpec.Repo.Migrations.CreateResourceAcknowledgements do
  use Ecto.Migration

  @moduledoc """
  A record that a resource is there on purpose.

  Keyed on what stays the same about a resource across rebuilds — its kind and
  where it lives — rather than on a row of ours. The resources most needing
  this are the ones setup never created and has no row for: a DNS record added
  by hand for another tool, mail records kept after moving providers.

  Account grain, because that is the grain the resources page reads at, and
  because a leftover belongs to the account rather than to whichever project
  happened to make it.
  """

  def change do
    create table(:resource_acknowledgements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :location, :string, null: false
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    # One acknowledgement per resource. Marking twice is a double click, not a
    # second opinion.
    create unique_index(:resource_acknowledgements, [:account_id, :kind, :location])
    create index(:resource_acknowledgements, [:account_id])
  end
end
