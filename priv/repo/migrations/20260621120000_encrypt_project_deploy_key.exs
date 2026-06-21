defmodule CodeMySpec.Repo.Migrations.EncryptProjectDeployKey do
  use Ecto.Migration

  @moduledoc """
  Encrypts `projects.deploy_key` at rest via Cloak (CodeMySpec.Encrypted.Binary).

  Adds a bytea column, re-stores any existing plaintext keys as Cloak ciphertext,
  then drops the old text column and renames the encrypted one into place. Done
  this way (rather than an in-place ALTER ... USING) so ciphertext only ever
  lands in a binary column.
  """

  def up do
    alter table(:projects) do
      add :deploy_key_encrypted, :binary
    end

    flush()

    %{rows: rows} =
      repo().query!("SELECT id, deploy_key FROM projects WHERE deploy_key IS NOT NULL")

    migrate_rows(rows, &CodeMySpec.Vault.encrypt!/1, "deploy_key_encrypted")

    alter table(:projects) do
      remove :deploy_key
    end

    rename table(:projects), :deploy_key_encrypted, to: :deploy_key
  end

  def down do
    alter table(:projects) do
      add :deploy_key_plaintext, :string
    end

    flush()

    %{rows: rows} =
      repo().query!("SELECT id, deploy_key FROM projects WHERE deploy_key IS NOT NULL")

    migrate_rows(rows, &CodeMySpec.Vault.decrypt!/1, "deploy_key_plaintext")

    alter table(:projects) do
      remove :deploy_key
    end

    rename table(:projects), :deploy_key_plaintext, to: :deploy_key
  end

  defp migrate_rows([], _fun, _column), do: :ok

  defp migrate_rows(rows, fun, column) do
    ensure_vault!()

    Enum.each(rows, fn [id, value] ->
      repo().query!("UPDATE projects SET #{column} = $1 WHERE id = $2", [fun.(value), id])
    end)
  end

  # The Vault GenServer isn't part of the migration's supervision tree; start it
  # on demand (its key is statically configured in config.exs).
  defp ensure_vault! do
    case CodeMySpec.Vault.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
