defmodule CodeMySpec.Intake.Interviewer.Scripted do
  @moduledoc """
  A fixed interview, for when there is no model to reach.

  Deterministic and offline, which makes it the right implementation for tests
  whatever the default becomes. The questions are the ones worth asking of
  almost any application, so a visitor who hits this still gets a real
  conversation rather than an apology.
  """

  @behaviour CodeMySpec.Intake.Interviewer

  alias CodeMySpec.Intake.{Plan, Turn}

  @questions [
    "Who does the very first thing in this application, and what are they trying to get done?",
    "What should never be allowed to happen, even by accident?",
    "When something goes wrong, who needs to find out, and how?",
    "What would make you say this was worth building?"
  ]

  @impl true
  def ask(%Plan{}, turns) do
    case Enum.at(@questions, length(turns)) do
      nil -> {:error, :no_more_questions}
      question -> {:ok, question}
    end
  end

  @impl true
  def derive(%Plan{} = plan, turns) do
    rules =
      turns
      |> Enum.filter(& &1.answer)
      |> Enum.map(&rule_from/1)

    {:ok, [plan_rule(plan) | rules]}
  end

  defp plan_rule(%Plan{needs_sign_in: true}), do: "People sign in before they can use it."
  defp plan_rule(%Plan{}), do: "Anyone can use it without signing in."

  # Echoes the answer back as a rule. Plain, and honest about being derived
  # from what they said rather than reasoned about.
  defp rule_from(%Turn{answer: answer}), do: String.trim(answer)
end
