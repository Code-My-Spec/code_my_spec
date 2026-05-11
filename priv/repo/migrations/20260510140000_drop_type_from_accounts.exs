defmodule CodeMySpec.Repo.Migrations.DropTypeFromAccounts do
  use Ecto.Migration

  @moduledoc """
  Drops the `type` column from accounts. The personal/team distinction
  is gone — every account is created explicitly during onboarding.
  Existing rows lose their `:personal` / `:team` tag; no downstream
  code depends on it any more.
  """

  def change do
    alter table(:accounts) do
      remove :type
    end
  end
end
