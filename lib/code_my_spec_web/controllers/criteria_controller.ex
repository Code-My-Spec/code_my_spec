defmodule CodeMySpecWeb.CriteriaController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Stories

  action_fallback CodeMySpecWeb.FallbackController

  def list_for_story(conn, %{"story_id" => story_id}) do
    scope = conn.assigns.current_scope
    story_id = coerce_story_id(story_id)
    criteria = AcceptanceCriteria.list_story_criteria(scope, story_id)
    render(conn, :index, criteria: criteria)
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case AcceptanceCriteria.get_criterion(scope, coerce_id(id)) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      criterion -> render(conn, :show, criterion: criterion)
    end
  end

  def create(conn, %{"criterion" => attrs}) do
    scope = conn.assigns.current_scope
    story_id = attrs["story_id"]

    with %{} = story <- Stories.get_story(scope, story_id) || {:error, :story_not_found},
         {:ok, criterion} <-
           AcceptanceCriteria.create_criterion(scope, story, atomize_attrs(attrs)) do
      conn |> put_status(:created) |> render(:show, criterion: criterion)
    else
      {:error, :story_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "story_not_found"})

      {:error, :cross_project} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_project"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "criterion" => attrs}) do
    scope = conn.assigns.current_scope

    with %{} = criterion <-
           AcceptanceCriteria.get_criterion(scope, coerce_id(id)) || {:error, :not_found},
         {:ok, updated} <-
           AcceptanceCriteria.update_criterion(scope, criterion, atomize_attrs(attrs)) do
      render(conn, :show, criterion: updated)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :cross_project} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_project"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with %{} = criterion <-
           AcceptanceCriteria.get_criterion(scope, coerce_id(id)) || {:error, :not_found},
         {:ok, deleted} <- AcceptanceCriteria.delete_criterion(scope, criterion) do
      render(conn, :show, criterion: deleted)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  defp coerce_id(id) when is_integer(id), do: id
  defp coerce_id(id) when is_binary(id), do: String.to_integer(id)

  defp coerce_story_id(id), do: coerce_id(id)

  defp atomize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.delete("story_id")
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_existing_atom(k), v)
    end)
  rescue
    ArgumentError -> attrs
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
