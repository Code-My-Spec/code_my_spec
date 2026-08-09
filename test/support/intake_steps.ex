defmodule CodeMySpecSpex.IntakeSteps do
  @moduledoc """
  Driving the guided intake the way a visitor does.

  The shaping questions are asked one at a time, so a spec that needs a
  visitor past them has to answer them one at a time. Every spec used to post
  all three as a single form payload, which is how a page of dropdowns
  survived a rule that never sanctioned it — thirteen specs agreed with the
  implementation because they were written against it.

  Import where a spec needs a plan that has got past the questions:

      import CodeMySpecSpex.IntakeSteps

      view |> describe_idea("a booking tool for hair salons") |> answer_shaping_questions()
  """

  import Phoenix.LiveViewTest

  @default_answers ["yes", "yes", "salon owners"]

  @doc "Submits the opening description and returns the view."
  def describe_idea(view, description) do
    view
    |> form("form[phx-submit=describe]", %{description: description})
    |> render_submit()

    view
  end

  @doc """
  Answers each shaping question in turn until none is left.

  Bounded by the number of answers given rather than looping until the form
  disappears, so a spec fails on its own assertion rather than hanging if the
  conversation stops advancing.
  """
  def answer_shaping_questions(view, answers \\ @default_answers) do
    Enum.reduce(answers, render(view), fn answer, html ->
      if has_element?(view, "form[phx-submit=answer]") do
        view |> form("form[phx-submit=answer]", %{answer: answer}) |> render_submit()
      else
        html
      end
    end)
  end
end
