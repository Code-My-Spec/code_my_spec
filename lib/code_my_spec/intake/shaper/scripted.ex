defmodule CodeMySpec.Intake.Shaper.Scripted do
  @moduledoc """
  A shaper for tests: one question, then a reading of what was said.

  Not a fallback. Production has no offline path here — the conversation is the
  product, and a questionnaire standing in for it is the thing this replaced.
  This exists so specs can drive the conversation without a model call, and to
  keep the shape of the contract honest: ask at most once, then conclude.

  The reading is deliberately crude — it looks for the words a person would
  use. A real inference is the model's job; this only has to be deterministic.
  """

  @behaviour CodeMySpec.Intake.Shaper

  alias CodeMySpec.Intake.Plan

  @question "Who's going to be using this day to day, and what do they do with it?"

  @impl true
  def shape(%Plan{} = _plan, []), do: {:ask, @question}
  def shape(%Plan{} = plan, turns), do: conclude(plan, turns)

  @impl true
  def conclude(%Plan{} = plan, turns) do
    said = [plan.description | Enum.map(turns, & &1.answer)] |> Enum.join(" ") |> String.downcase()

    {:ok,
     %{
       needs_sign_in: mentions?(said, ~w(sign in log in login account clients customers users)),
       # "hair salons" is who it is for, not how many copies there are. Only
       # explicit each-their-own phrasing counts, or every industry plural
       # would read as multitenancy.
       separate_copies: mentions?(said, ["each their own", "their own copy", "own instance"]),
       who_uses: who_uses(turns)
     }}
  end

  defp mentions?(said, words), do: Enum.any?(words, &String.contains?(said, &1))

  defp who_uses([]), do: "the people who run it"
  defp who_uses(turns), do: turns |> List.last() |> Map.fetch!(:answer) |> String.slice(0, 120)
end
