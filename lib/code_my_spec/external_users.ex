defmodule CodeMySpec.ExternalUsers do
  @moduledoc """
  Registered end-users of a target application, pushed to CodeMySpec.

  The push-based counterpart to `CodeMySpec.ProjectUsers`: web apps expose a
  `GET /api/cms/users` endpoint CodeMySpec pulls from live, but desktop apps
  have no backend to pull from — they upsert their users here (via the
  deploy-key authenticated widget API) so chat and issue reporting have a
  durable identity on the server. Keyed by `(project_id, email)`, matching how
  `Conversations` threads end-users.
  """

  import Ecto.Query

  alias CodeMySpec.ExternalUsers.ExternalUser
  alias CodeMySpec.Repo

  @doc """
  Creates or refreshes the external user identified by `email` on the given
  project. A repeat upsert overwrites `external_id`, `name`, and `metadata`
  with the incoming values — the target app is the source of truth for its
  own users.
  """
  @spec upsert_external_user(String.t(), String.t(), map()) ::
          {:ok, ExternalUser.t()} | {:error, Ecto.Changeset.t()}
  def upsert_external_user(account_id, project_id, attrs)
      when is_binary(account_id) and is_binary(project_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("account_id", account_id)
      |> Map.put("project_id", project_id)

    %ExternalUser{}
    |> ExternalUser.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:external_id, :name, :metadata, :updated_at]},
      conflict_target: [:project_id, :email],
      returning: true
    )
  end

  @doc """
  Lists a project's external users, most recently active (upserted) first.
  """
  @spec list_external_users(String.t()) :: [ExternalUser.t()]
  def list_external_users(project_id) when is_binary(project_id) do
    from(u in ExternalUser,
      where: u.project_id == ^project_id,
      order_by: [desc: u.updated_at]
    )
    |> Repo.all()
  end
end
