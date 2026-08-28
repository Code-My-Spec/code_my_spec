defmodule CodeMySpec.Intake.BudgetTest do
  @moduledoc """
  Story 875: ten turns on our credential is the whole budget.

  A visitor who signs up through intake has connected no provider, so every
  model call before they connect one is ours to pay for — and this funnel leaks
  by design, so we pay for plenty that nobody comes back to read.

  ## Why there is no counter

  The budget is already spent by four call sites with caps of their own, put
  there for their own reasons: an intake that keeps asking is worse than one
  that guesses and shows its guess. Adding a turn counter on top would be a
  second mechanism bounding something already bounded, and two mechanisms that
  can disagree eventually do.

  So this asserts the arithmetic instead. Raising either cap is a legitimate
  thing to want; doing it without noticing you have moved the spend is not, and
  this is what makes the second one fail loudly.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Intake.{Interview, Shaper}

  # What John set, 2026-08-28.
  @budget 10

  test "a visitor cannot cost us more than the budget before they connect a provider" do
    # Shaping: one call per question, then one to conclude when the cap is hit.
    shaping = Shaper.max_questions() + 1

    # Planning: once, when shaping concludes.
    planning = 1

    # The interview: one call per question, then one to derive the rules.
    interview = Interview.question_cap() + 1

    total = shaping + planning + interview

    assert total <= @budget,
           """
           Intake can now spend #{total} model calls on our credential, over a \
           budget of #{@budget}.

           Shaping #{shaping}, planning #{planning}, interview #{interview}.

           Nothing counts turns at runtime — the bound is these caps multiplied \
           out — so raising one moves what we pay for every visitor who never \
           comes back, and nothing else would have said so.
           """
  end
end
