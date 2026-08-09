defmodule CodeMySpecSpex.IntakeSteps do
  @moduledoc """
  Driving the guided intake the way a visitor does.

  The shaping step is a conversation, so a spec that needs a visitor past it
  answers in sentences, not in fields. Specs used to post three form values in
  one go, which is how a page of dropdowns survived a rule that never
  sanctioned it — every spec agreed with the implementation because each was
  written against it.

  How many questions get asked is the shaper's business, not the spec's, so
  this answers whatever is on screen until the conversation ends.

  Import where a spec needs a plan that has got past the questions:

      import CodeMySpecSpex.IntakeSteps

      view |> describe_idea("a booking tool for hair salons") |> answer_shaping_questions()
  """

  import Phoenix.LiveViewTest

  @default_answers ["salon owners see their week, and their clients book themselves in"]

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
