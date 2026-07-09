defmodule CodeMySpecLocalWeb.Hooks.AskUserQuestionController do
  @moduledoc """
  Routes a Claude Code `AskUserQuestion` tool call to the user's phone.

  Fired by a dedicated PreToolUse matcher (no `--max-time`, so it can block).
  Posts the questions to production — which pushes a Web Push notification — and
  blocks until the user answers in `QuestionLive.Show`. The answer is returned to
  the model by denying the tool with the answer as the reason, so the agent never
  shows the local prompt and continues with the remote choice.

  Falls through (empty `{}`, letting the normal terminal prompt run) when the
  user isn't connected to production, on timeout, or on any error — the local
  experience is never worse than before.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Notifications.QuestionClient

  def handle(conn, params) do
    questions = get_in(params, ["tool_input", "questions"]) || []

    with true <- is_list(questions) and questions != [],
         {:ok, id} <- QuestionClient.ask(questions),
         {:ok, answers} <- QuestionClient.await_answer(id) do
      Logger.info("[AskUserQuestion] answered remotely (#{map_size(answers)} question(s))")
      json(conn, deny_with_answer(answers))
    else
      {:error, :not_configured} ->
        json(conn, %{})

      {:error, reason} ->
        Logger.info("[AskUserQuestion] falling back to local prompt: #{inspect(reason)}")
        json(conn, %{})

      _ ->
        json(conn, %{})
    end
  end

  # Deny the tool so the local prompt never shows; hand the model the answer.
  defp deny_with_answer(answers) do
    reason = "The user answered on their phone:\n" <> format_answers(answers)

    %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => reason
      }
    }
  end

  defp format_answers(answers) do
    Enum.map_join(answers, "\n", fn {question, answer} -> "- #{question}: #{format_answer(answer)}" end)
  end

  defp format_answer(answer) when is_list(answer), do: Enum.join(answer, ", ")
  defp format_answer(answer), do: to_string(answer)
end
