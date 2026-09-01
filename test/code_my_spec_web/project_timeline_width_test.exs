defmodule CodeMySpecWeb.ProjectTimelineWidthTest do
  @moduledoc """
  The strip stays narrow enough for a phone, guarded by what makes it narrow.

  Issue 5e507418. At 390px the strip used to overflow and clip mid-word —
  `SHAPING`, its two steps, then `DI`, the start of `DESIGN`, and nothing after,
  with no scrollbar or fade to suggest there was more. A project in BUILDING saw
  no sign that its own phase existed, which is worse than showing nothing: the
  strip looked complete.

  Fixed by dropping the phase *names* from the strip and keeping the shapes — a
  phase you are not in is one pie, the phase you are in is its steps. Verified in
  a real browser at 390×844 on the widest case: Design has five steps, more than
  any other phase, and expanded it still sits on one line with room after it.

  ## What this can and cannot check

  Not the clipping. That is a layout fact the rendered HTML does not carry, which
  is exactly why criterion 2940 passed while the strip was unreadable — it counts
  marks, and the marks were all present and off-screen.

  What it can check are the two facts that make it fit, either of which could be
  undone without a single mark-count changing.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.PlainLanguage

  defp steps_per_phase do
    PlainLanguage.phases()
    |> Enum.map(fn {key, _label} ->
      count =
        PlainLanguage.order()
        |> Enum.count(fn name ->
          case PlainLanguage.fetch(name) do
            %{phase: ^key} -> true
            _ -> false
          end
        end)

      {key, count}
    end)
  end

  test "no phase is wider than five steps" do
    counts = steps_per_phase()
    {_phase, widest} = Enum.max_by(counts, &elem(&1, 1))

    assert widest <= 5,
           "a phase now has #{widest} steps. The strip fits at 390px because the widest " <>
             "expanded phase is five marks; growing one past that is the change most " <>
             "likely to put the clipping back, and no mark-counting assertion would " <>
             "notice. Re-check in a browser at 390x844. Counts: #{inspect(counts)}"
  end

  test "a phase name never renders as visible text in the strip" do
    markup =
      "lib/code_my_spec_web/project_timeline.ex"
      |> File.read!()
      |> String.split("~H\"\"\"")
      |> Enum.at(1)
      |> to_string()

    offenders =
      markup
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "phase.label"))
      # The two places a name is free: the hover title, and a screen-reader span
      # that is visually hidden. Both were deliberate — the name still reaches
      # anyone who needs it, without occupying a pixel.
      |> Enum.reject(&(String.contains?(&1, "title=") or String.contains?(&1, "sr-only")))

    assert offenders == [],
           "a phase name is being rendered as visible text again: #{inspect(offenders)}. " <>
             "That is what made the strip overflow at 390px — SHAPING, its steps, then " <>
             "DI, and BUILDING, CHECKING and PROVING off-screen with nothing saying so. " <>
             "The name belongs in the title or an sr-only span, where it costs no width."
  end

  test "the two free places are still there, so the name is not simply gone" do
    source = File.read!("lib/code_my_spec_web/project_timeline.ex")

    assert source =~ "sr-only",
           "the screen-reader name went with the visible one. Dropping the names to fit " <>
             "a phone was a layout decision, not a decision to stop saying which phase " <>
             "is which — a strip of unlabelled shapes with nothing behind them is " <>
             "unreadable to anyone not looking at it."
  end
end
