defmodule CodeMySpecWeb.PersonasController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Personas

  action_fallback CodeMySpecWeb.FallbackController

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    personas = Personas.list_personas(scope)
    render(conn, :index, personas: personas)
  end

  def list_for_story(conn, %{"story_id" => story_id}) do
    scope = conn.assigns.current_scope
    personas = Personas.list_personas_for_story(scope, String.to_integer(story_id))
    render(conn, :index, personas: personas)
  end

  def list_for_project(conn, %{"project_id" => project_id}) do
    scope = conn.assigns.current_scope
    personas = Personas.list_personas_for_project(scope, project_id)
    render(conn, :index, personas: personas)
  end

  def list_project_link_edges(conn, %{"project_id" => project_id}) do
    scope = conn.assigns.current_scope
    edges = Personas.list_project_persona_story_links(scope, project_id)

    data =
      Enum.map(edges, fn {persona_id, story_id} ->
        %{persona_id: persona_id, story_id: story_id}
      end)

    json(conn, %{data: data})
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Personas.get_persona(scope, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Persona not found"})

      persona ->
        render(conn, :show, persona: persona)
    end
  end

  def show_by_slug(conn, %{"slug" => slug}) do
    scope = conn.assigns.current_scope

    case Personas.get_persona_by_slug(scope, slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "not_found", error: "Persona not found"})

      persona ->
        render(conn, :show, persona: persona)
    end
  end

  def create(conn, %{"persona" => attrs}) do
    scope = conn.assigns.current_scope

    case Personas.create_persona(scope, attrs) do
      {:ok, persona} ->
        conn
        |> put_status(:created)
        |> render(:show, persona: persona)

      {:error, :missing_active_account} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "missing_active_account"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "persona" => attrs}) do
    scope = conn.assigns.current_scope

    with %{} = persona <- Personas.get_persona(scope, id) || {:error, :not_found},
         {:ok, updated} <- Personas.update_persona(scope, persona, attrs) do
      render(conn, :show, persona: updated)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :cross_account} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_account"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with %{} = persona <- Personas.get_persona(scope, id) || {:error, :not_found},
         {:ok, deleted} <- Personas.delete_persona(scope, persona) do
      render(conn, :show, persona: deleted)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  # Nested `resources "/personas"` routes supply `personas_id` as the path
  # param (Phoenix's literal-pluralization for non-inflecting names). Fall
  # back to `"id"` so the action works whether called under `resources` or a
  # non-nested route.
  def link_story(conn, %{"story_id" => story_id} = params) do
    scope = conn.assigns.current_scope
    persona_id = params["personas_id"] || params["id"]

    case Personas.link_persona_to_story(scope, persona_id, coerce_story_id(story_id)) do
      {:ok, link} ->
        conn
        |> put_status(:created)
        |> json(%{data: persona_story_data(link)})

      {:error, :cross_account} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_account"})

      {:error, :missing_active_account} ->
        conn |> put_status(:unauthorized) |> json(%{error: "missing_active_account"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def unlink_story(conn, %{"story_id" => story_id} = params) do
    scope = conn.assigns.current_scope
    persona_id = params["personas_id"] || params["id"]

    case Personas.unlink_persona_from_story(scope, persona_id, coerce_story_id(story_id)) do
      {:ok, :unlinked} -> json(conn, %{status: "unlinked"})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  defp coerce_story_id(id) when is_integer(id), do: id
  defp coerce_story_id(id) when is_binary(id), do: String.to_integer(id)

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  defp persona_story_data(link) do
    %{
      id: link.id,
      persona_id: link.persona_id,
      story_id: link.story_id,
      inserted_at: link.inserted_at,
      updated_at: link.updated_at
    }
  end
end
