defmodule CodeMySpecWeb.IntakeLive.ComposerClearsTest do
  @moduledoc """
  What the visitor sent leaves the box.

  The textarea had no rendered value, so the DOM patch had nothing to set and
  what they typed survived the submit — sitting there looking unsent. The next
  thing anyone does with an answer that looks unsent is send it again, and now
  that the conversation serialises turns, that is two turns and two model calls
  from one thought.

  `AgentConversationLive` carries the same attribute and its comment says it
  cost a duplicate send in real use. The intake composer was written without it.

  The value is `@draft` rather than a hardcoded `""` because every broadcast is
  a patch: with an empty literal, the "Thinking…" bubble alone would wipe a
  half-written answer.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "the box is empty after sending", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    html =
      view
      |> form("form[phx-submit=describe]", %{description: "a mahjong game with an ai coach"})
      |> render_submit()

    refute html =~ "a mahjong game with an ai coach</textarea>",
           "what was sent is still sitting in the box. It looks unsent, and the " <>
             "obvious next move is to send it again — which is now two turns and " <>
             "two model calls from one thought."
  end

  test "and a half-written answer survives a redraw", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    view
    |> form("form[phx-submit=describe]", %{description: "a mahjong game with an ai coach"})
    |> render_submit()

    # Typing, not sending.
    view |> element("form[phx-submit=answer]") |> render_change(%{"answer" => "half a thought"})

    # Something unrelated redraws the form.
    html = render(view)

    assert html =~ "half a thought",
           "a redraw threw away what the visitor was in the middle of typing. That " <>
             "is what a hardcoded empty value buys, and it is worse than the bug it " <>
             "fixes."
  end
end
