defmodule CodeMySpec.Repo.References do
  @moduledoc """
  Foreign keys as changeset errors on SQLite.

  SQLite reports a foreign-key failure without naming the constraint, so
  `assoc_constraint/3` and `foreign_key_constraint/3` cannot turn it into a
  changeset error there; the write raises instead. On SQLite this checks the
  references a changeset declares, just before the write, and adds the same
  error the constraint would have. On Postgres it changes nothing.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @spec check(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def check(changeset) do
    if CodeMySpec.Repo.sqlite?(), do: prepare_changes(changeset, &check_now/1), else: changeset
  end

  defp check_now(changeset) do
    Enum.reduce(changeset.constraints, changeset, fn
      %{type: :foreign_key, field: field, error_message: message}, acc ->
        check_reference(acc, field, message)

      _constraint, acc ->
        acc
    end)
  end

  defp check_reference(changeset, field, message) do
    with %Ecto.Association.BelongsTo{} = assoc <- belongs_to(changeset.data.__struct__, field),
         value when not is_nil(value) <- get_field(changeset, assoc.owner_key),
         false <- exists?(changeset.repo, assoc, value) do
      add_error(changeset, field, message, constraint: :foreign_key)
    else
      _ -> changeset
    end
  end

  # `assoc_constraint` names the association; `foreign_key_constraint` names
  # its key.
  defp belongs_to(schema, field) do
    schema.__schema__(:association, field) ||
      Enum.find_value(schema.__schema__(:associations), fn name ->
        assoc = schema.__schema__(:association, name)
        if match?(%Ecto.Association.BelongsTo{owner_key: ^field}, assoc), do: assoc
      end)
  end

  defp exists?(repo, %{related: related, related_key: key}, value),
    do: repo.exists?(from(r in related, where: field(r, ^key) == ^value))
end
