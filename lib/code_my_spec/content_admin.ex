defmodule CodeMySpec.ContentAdmin do
  @moduledoc """
  The ContentAdmin Context manages content validation and preview within the CodeMySpec SaaS platform.

  This is a minimal validation layer - developers sync from Git to see if their content parses correctly.
  When ready to publish, they click "Push to Client" which triggers a fresh sync from Git -> Client
  (bypassing ContentAdmin).
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.ContentAdmin.{ContentAdmin, ContentAdminRepository}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Returns all content admin records for the given scope.
  """
  @spec list_all_content(Scope.t()) :: [ContentAdmin.t()]
  def list_all_content(%Scope{} = scope) do
    ContentAdminRepository.list_content(scope)
  end

  @doc """
  Returns content admin records with parse errors for the given scope.
  """
  @spec list_content_with_errors(Scope.t()) :: [ContentAdmin.t()]
  def list_content_with_errors(%Scope{} = scope) do
    ContentAdminRepository.list_content_with_errors(scope)
  end

  @doc """
  Returns content admin records filtered by parse status.
  """
  @spec list_by_parse_status(Scope.t(), :success | :error) :: [ContentAdmin.t()]
  def list_by_parse_status(%Scope{} = scope, status) when status in [:success, :error] do
    ContentAdmin
    |> where([c], c.account_id == ^scope.active_account.id)
    |> where([c], c.project_id == ^scope.active_project.id)
    |> where([c], c.parse_status == ^status)
    |> Repo.all()
  end

  @doc """
  Gets a single content admin record. Raises if not found.
  """
  @spec get_content!(Scope.t(), integer()) :: ContentAdmin.t()
  def get_content!(%Scope{} = scope, id) do
    ContentAdminRepository.get_content!(scope, id)
  end

  @doc """
  Gets a content admin record by slug and content type.
  Returns nil if not found.
  """
  @spec get_by_slug(Scope.t(), String.t(), atom()) :: ContentAdmin.t() | nil
  def get_by_slug(%Scope{} = scope, slug, content_type) when is_atom(content_type) do
    content_type_str = Atom.to_string(content_type)

    ContentAdmin
    |> where([c], c.account_id == ^scope.active_account.id)
    |> where([c], c.project_id == ^scope.active_project.id)
    |> where([c], fragment("?->>'slug' = ?", c.metadata, ^slug))
    |> where([c], fragment("?->>'content_type' = ?", c.metadata, ^content_type_str))
    |> Repo.one()
  end

  @doc """
  Creates multiple content admin records in a transaction.
  """
  @spec create_many(Scope.t(), [map()]) :: {:ok, [ContentAdmin.t()]} | {:error, term()}
  def create_many(%Scope{} = scope, content_list) do
    require Logger

    # Build changesets first
    changesets =
      Enum.with_index(content_list, fn attrs, index ->
        attrs = add_scope_to_attrs(scope, attrs)

        changeset =
          %ContentAdmin{}
          |> ContentAdmin.changeset(attrs)

        {changeset, index}
      end)

    # Log validation errors
    changesets
    |> Enum.filter(fn {cs, _index} -> not cs.valid? end)
    |> Enum.each(fn {cs, index} ->
      errors =
        Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", to_string(value))
          end)
        end)

      title = get_in(cs.changes, [:metadata, "title"]) || "untitled"
      error_string = CodeMySpec.Utils.changeset_error_to_string(cs)

      Logger.error(
        "ContentAdmin validation failed at index #{index}: #{title} - #{error_string} errors=#{inspect(errors)}"
      )
    end)

    # Check if any changesets are invalid
    case Enum.find(changesets, fn {cs, _index} -> not cs.valid? end) do
      nil ->
        insert_all_changesets(scope, changesets)

      {invalid_changeset, index} ->
        Logger.error("Aborting create_many due to validation failure at index #{index}")
        {:error, invalid_changeset}
    end
  end

  defp insert_all_changesets(scope, changesets) do
    Repo.transaction(fn ->
      Enum.map(changesets, fn {changeset, _index} ->
        Repo.insert!(changeset)
      end)
    end)
    |> case do
      {:ok, content_list} = result ->
        broadcast_content_change(scope, {:sync_completed, length(content_list)})
        result

      error ->
        error
    end
  end

  @doc """
  Deletes all content admin records for the given scope.
  """
  @spec delete_all_content(Scope.t()) :: {:ok, integer()}
  def delete_all_content(%Scope{} = scope) do
    {count, _} =
      ContentAdmin
      |> where([c], c.account_id == ^scope.active_account.id)
      |> where([c], c.project_id == ^scope.active_project.id)
      |> Repo.delete_all()

    broadcast_content_change(scope, :bulk_delete)
    {:ok, count}
  end

  @doc """
  Returns counts of content by parse status.
  """
  @spec count_by_parse_status(Scope.t()) :: %{success: integer(), error: integer()}
  def count_by_parse_status(%Scope{} = scope) do
    success_count =
      ContentAdmin
      |> where([c], c.account_id == ^scope.active_account.id)
      |> where([c], c.project_id == ^scope.active_project.id)
      |> where([c], c.parse_status == :success)
      |> Repo.aggregate(:count)

    error_count =
      ContentAdmin
      |> where([c], c.account_id == ^scope.active_account.id)
      |> where([c], c.project_id == ^scope.active_project.id)
      |> where([c], c.parse_status == :error)
      |> Repo.aggregate(:count)

    %{success: success_count, error: error_count}
  end

  # Private Helpers

  defp add_scope_to_attrs(%Scope{} = scope, attrs) do
    attrs
    |> Map.put(:account_id, scope.active_account.id)
    |> Map.put(:project_id, scope.active_project.id)
  end

  defp broadcast_content_change(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      content_admin_topic(scope),
      message
    )
  end

  defp content_admin_topic(%Scope{} = scope) do
    "account:#{scope.active_account.id}:project:#{scope.active_project.id}:content_admin"
  end
end
