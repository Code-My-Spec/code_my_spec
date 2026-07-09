defmodule CodeMySpecWeb.QuestionController do
  @moduledoc """
  API for remote `AskUserQuestion` requests from Claude Code.

  Protected by OAuth — the local server authenticates via its stored token.
  The local hook `ask`s (which pushes a notification), then polls `status`
  until the user answers from `QuestionLive.Show`.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Notifications

  @doc "POST /api/questions/ask — create a question request and push it."
  def ask(conn, %{"questions" => questions} = params) when is_list(questions) do
    scope = conn.assigns.current_scope

    attrs = %{"questions" => questions, "title" => Map.get(params, "title")}

    case Notifications.create_question_request(scope.user.id, attrs) do
      {:ok, request} -> conn |> put_status(:created) |> json(%{id: request.id})
      {:error, changeset} -> conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})
    end
  end

  def ask(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing required field: questions (a list)"})
  end

  @doc "POST /api/questions/:id/answer — record the user's answers."
  def answer(conn, %{"id" => id, "answers" => answers}) when is_map(answers) do
    with %{user_id: uid} = _req <- authorized(conn, id),
         true <- uid == conn.assigns.current_scope.user.id do
      case Notifications.answer_question_request(id, answers) do
        {:ok, _} -> json(conn, %{status: "ok"})
        {:error, {:already_resolved, status}} -> conn |> put_status(:conflict) |> json(%{error: "Already #{status}"})
        {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  def answer(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing required fields: id, answers (a map)"})
  end

  @doc "GET /api/questions/:id/status — poll for the answer."
  def status(conn, %{"id" => id}) do
    with %{user_id: uid} = request <- authorized(conn, id),
         true <- uid == conn.assigns.current_scope.user.id do
      json(conn, %{id: request.id, status: request.status, answers: request.answers})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Not found"})
      false -> conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  defp authorized(_conn, id), do: Notifications.get_question_request(id)
end
