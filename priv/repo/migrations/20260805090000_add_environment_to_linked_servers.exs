defmodule CodeMySpec.Repo.Migrations.AddEnvironmentToLinkedServers do
  use Ecto.Migration

  @moduledoc """
  What a linked server is for, in Sam's words.

  A free string rather than an enum, deliberately. `prod` is not a concept the
  code branches on — it is a value, the same as `uat` or `qa-story-812`. An
  enum would put back the hardcoded `["prod", "uat"]` that
  `provisioning_environments` was created to remove, and could not hold a
  per-story environment at all.

  Nullable, because an unlabelled box is a real state and the honest answer for
  one nobody has claimed yet — which is exactly the box story 994 exists to put
  in front of him.

  No default here; the schema carries it. Defaults in migrations bind the
  database to a decision the application should own.
  """

  def change do
    alter table(:linked_servers) do
      add :environment, :string
    end

    create index(:linked_servers, [:account_id, :environment])
  end
end
