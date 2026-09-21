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

  # Named after the *configured model*'s provider, not a fixed one — the same
  # bug `Planner.default_impl/0` already fixed once (`5a5708a7`'s sibling):
  # hardcoding `:anthropic_api_key` here answered "no key" for a deployment
  # running a `claude_code:` or `openai:` model that never needed one, and
  # fell through to `Scripted` silently.
  defp default_impl do
    if CodeMySpec.Intake.Agent.key_configured?(model()) do
      CodeMySpec.Intake.Interviewer.Llm
    else
      CodeMySpec.Intake.Interviewer.Scripted
    end
  end

  defp model do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Intake, [])
    |> Keyword.get(:model, "anthropic:claude-sonnet-5")
  end
end
