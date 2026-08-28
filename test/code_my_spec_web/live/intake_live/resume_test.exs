defmodule CodeMySpecWeb.IntakeLive.ResumeTest do
  @moduledoc """
  A visitor coming back mid-conversation gets asked something.

  The shaping turns live in socket assigns, so a reload keeps the plan row and
  loses the question that was on screen. What remains renders as the visitor's
  description followed by an empty answer box — a box with nothing above it to
  answer, which is not a state anybody can act on.

  Reachable the slow way (reload, reconnect, come back tomorrow) and, for 25
  days, the fast way: production had no provider key, so every `shape/2` errored
  and every visitor's plan stopped at `:answering` with no question ever asked.
  Setting the key does not clear those rows — they are still sitting at
  `:answering` — so resuming has to be able to pick the conversation back up.
  This is the state the bug report arrived in.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "a plan stranded at :answering is asked the next question on mount", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    view
    |> form("form[phx-submit=describe]", %{description: "an AI mahjong coach for beginners"})
    |> render_submit()

    # Coming back to it: same browser, same cookie, a fresh LiveView with none
    # of the first one's assigns.
    {:ok, _resumed, html} = live(conn, "/build")

    # Opening question, the visitor's description, and something to answer.
    assert count_said(html) >= 3,
           "the visitor came back to their own description and an answer box with " <>
             "nothing above it to answer. The turns live in socket assigns, so a " <>
             "reload loses the question — and the row stays at :answering, so this " <>
             "is where every plan stranded by the 25-day outage still sits. " <>
             "Transcript entries: #{count_said(html)}."

    assert html =~ ~s(phx-submit="answer"),
           "there is a question but no box to answer it in"
  end

  defp count_said(html),
    do: html |> String.split(~s(data-test="intake-said")) |> length() |> Kernel.-(1)
end
