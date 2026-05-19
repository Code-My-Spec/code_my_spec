defmodule CodeMySpec.ContentAdmin.ContentAdminRepository do
  @moduledoc false
  import Ecto.Query, warn: false
  alias CodeMySpec.Repo
  alias CodeMySpec.ContentAdmin.ContentAdmin
  alias CodeMySpec.Users.Scope

  @doc """
  Returns all content admin records for the given scope.
  """
  def list_content(%Scope{} = scope) do
    ContentAdmin
    |> where([c], c.account_id == ^scope.active_account.id)
    |> where([c], c.project_id == ^scope.active_project.id)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns content admin records with parse errors for the given scope.
  """
  def list_content_with_errors(%Scope{} = scope) do
    ContentAdmin
    |> where([c], c.account_id == ^scope.active_account.id)
    |> where([c], c.project_id == ^scope.active_project.id)
    |> where([c], c.parse_status == :error)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single content admin record for the given scope.
  Raises `Ecto.NoResultsError` if not found.
  """
  def get_content!(%Scope{} = scope, id) do
    ContentAdmin
    |> where([c], c.id == ^id)
    |> where([c], c.account_id == ^scope.active_account.id)
    |> where([c], c.project_id == ^scope.active_project.id)
    |> Repo.one!()
  end

  @doc """
  Gets a single content admin record for the given scope.
  Returns nil if not found.
  """
  def get_content(%Scope{} = scope, id) do
    ContentAdmin
    |> where([c], c.id == ^id)
    |> where([c], c.account_id == ^scope.active_account.id)
    |> where([c], c.project_id == ^scope.active_project.id)
    |> Repo.one()
  end
end
