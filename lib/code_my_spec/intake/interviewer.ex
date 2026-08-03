defmodule CodeMySpec.Intake.Interviewer do
  @moduledoc """
  Asks the next question, and derives the rules once there are enough answers.

  Swappable for the same reason the planner is: the real one is a model call,
  and tests need an answer that is the same every run and costs nothing.

      config :code_my_spec, CodeMySpec.Intake, interviewer: MyInterviewer
  """

  alias CodeMySpec.Intake.{Plan, Turn}

  @doc "The next question to ask, given what has been said so far."
  @callback ask(Plan.t(), [Turn.t()]) :: {:ok, String.t()} | {:error, term()}

  @doc "The rules the answers imply, in the visitor's own terms."
  @callback derive(Plan.t(), [Turn.t()]) :: {:ok, [String.t()]} | {:error, term()}

  @spec ask(Plan.t(), [Turn.t()]) :: {:ok, String.t()} | {:error, term()}
  def ask(plan, turns), do: impl().ask(plan, turns)

  @spec derive(Plan.t(), [Turn.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def derive(plan, turns), do: impl().derive(plan, turns)

  defp impl do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get_lazy(:interviewer, &default_impl/0)
  end

  defp default_impl do
    case ReqLLM.get_key(:anthropic_api_key) do
      key when is_binary(key) and key != "" -> CodeMySpec.Intake.Interviewer.Llm
      _ -> CodeMySpec.Intake.Interviewer.Scripted
    end
  end
end
