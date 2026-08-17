defmodule CodeMySpec.Repo.Migrations.LiftAccountGrainSecretsWrittenPerProject do
  use Ecto.Migration

  @moduledoc """
  The second half of `48a6e127`.

  That migration moved the Hetzner API token to the account — "the same grain
  as the servers they name" — and taught `Hetzner.token/1` to read the account
  first. What it did not do was stop the provisioning form writing there, so
  every token entered since has gone to a grain the runtime does not read.

  The token only. The S3 key pair stayed on the project, and
  `Storage.credentials/2` still reads it there, so its read and write agree and
  there is nothing to lift. Marking those two account-grain as well — which is
  what the commit message's "the same grain as the servers they name" reads
  like it implies — takes the storage steps' credentials away from them, and
  seventeen spex say so immediately.

  Found by QA on story 850 (`bcd2b2b4`): a token typed into the page was stored
  on the project, the check called Hetzner — which resolved the *account*
  credential — and the page reported that result against the project field.
  Five accounts had accumulated stray project-grain rows this way.

  Copies up, never over: an account that already holds a value for a key keeps
  it, because that one is what its runs have been using and this migration is
  not the place to change which credential an account provisions with. The
  project rows are then removed, since nothing reads them and leaving a second
  copy of a credential around is the thing story 850 exists to prevent.
  """

  def up do
    # The newest project-grain row per (account, key) wins, on the same
    # reasoning the form has: the last thing typed is the current one.
    execute("""
    INSERT INTO project_secrets (account_id, project_id, key, value, environment, inserted_at, updated_at)
    SELECT DISTINCT ON (p.account_id, s.key, s.environment)
           p.account_id, NULL, s.key, s.value, s.environment, s.inserted_at, s.updated_at
      FROM project_secrets s
      JOIN projects p ON p.id = s.project_id
     WHERE s.key = 'hetzner_api_token'
       AND NOT EXISTS (
             SELECT 1 FROM project_secrets a
              WHERE a.account_id = p.account_id
                AND a.key = s.key
                AND a.environment = s.environment
           )
     ORDER BY p.account_id, s.key, s.environment, s.updated_at DESC
    """)

    execute("""
    DELETE FROM project_secrets
     WHERE project_id IS NOT NULL
       AND key = 'hetzner_api_token'
    """)
  end

  # Irreversible on purpose. Down would have to invent which project each
  # account-grain value came from, and the ones it lifted no longer exist to
  # ask. Restoring means restoring the backup.
  def down, do: :ok
end
