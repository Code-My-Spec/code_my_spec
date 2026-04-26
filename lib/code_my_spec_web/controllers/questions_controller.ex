defmodule CodeMySpecWeb.QuestionsController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Questions

  action_fallback CodeMySpecWeb.FallbackController

  def list_for_story(conn, %{"story_id" => story_id}) do
    scope = conn.assigns.current_scope
    questions = Questions.list_questions_for_story(scope, story_id)
    render(conn, :index, questions: questions)
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Questions.get_question(scope, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      question ->
        render(conn, :show, question: question)
    end
  end

  def create(conn, %{"question" => attrs}) do
    scope = conn.assigns.current_scope
    story_id = attrs["story_id"]

    case Questions.create_question(scope, story_id, Map.delete(attrs, "story_id")) do
      {:ok, question} ->
        conn |> put_status(:created) |> render(:show, question: question)

      {:error, :missing_active_scope} ->
        conn |> put_status(:unauthorized) |> json(%{error: "missing_active_scope"})

      {:error, :story_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "story_not_found"})

      {:error, :cross_account} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_account"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "question" => attrs}) do
    scope = conn.assigns.current_scope

    with %{} = question <- Questions.get_question(scope, id) || {:error, :not_found},
         {:ok, updated} <- Questions.update_question(scope, question, attrs) do
      render(conn, :show, question: updated)
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

    with %{} = question <- Questions.get_question(scope, id) || {:error, :not_found},
         {:ok, deleted} <- Questions.delete_question(scope, question) do
      render(conn, :show, question: deleted)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
