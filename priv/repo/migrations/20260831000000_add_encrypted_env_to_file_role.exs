defmodule CodeMySpec.Repo.Migrations.AddEncryptedEnvToFileRole do
  @moduledoc """
  `envs/{env}.enc.env` gets its own role, split out of the existence-only
  `:deploy_artifact` bucket, because it is the one deploy artifact whose
  *content* a provisioning check needs — which required secret names it
  declares — and that never needs decryption to answer: SOPS's dotenv mode
  encrypts values only, so key names are plaintext in the file as committed.
  The harness checks this the same way it already checks `mix.exs`/
  `.credo.exs`, at sync time, so the server never needs to reach the file
  itself for a harness-only project.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "ALTER TYPE file_role ADD VALUE IF NOT EXISTS 'encrypted_env'"
  end

  def down do
    :ok
  end
end
