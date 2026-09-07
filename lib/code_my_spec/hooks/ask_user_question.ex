defmodule CodeMySpec.Hooks.AskUserQuestion do
  @moduledoc """
  The AskUserQuestion hook.

  Answers a question the agent asked, if a human has already answered it. The
  deny-with-answer shape is how a hook returns content to the agent — see the
  controller's own note on why that reads as an error in the transcript.
  """

  require Logger

  alias CodeMySpec.Notifications.QuestionClient

  @spec handle(CodeMySpec.Users.Scope.t(), map()) :: {pos_integer(), map()}
  def handle(_scope, params) do
    questions = get_in(params, ["tool_input", "questions"]) || []

    with true <- is_list(questions) and questions != [],
         {:ok, id} <- QuestionClient.ask(questions),
         {:ok, answers} <- QuestionClient.await_answer(id) do
      Logger.info("[AskUserQuestion] answered remotely (#{map_size(answers)} question(s))")
      {200, deny_with_answer(answers)}
    else
      {:error, :not_configured} ->
        {200, %{}}

      {:error, reason} ->
        Logger.info("[AskUserQuestion] falling back to local prompt: #{inspect(reason)}")
        {200, %{}}

      _ ->
        {200, %{}}
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
