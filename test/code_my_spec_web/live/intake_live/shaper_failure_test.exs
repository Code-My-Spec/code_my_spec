defmodule CodeMySpecWeb.IntakeLive.ShaperFailureTest do
  @moduledoc """
  A model that cannot answer says so in the conversation.

  Reported from production, 2026-08-28: a visitor typed what they wanted to
  build and got their own answer back followed by nothing — no question, no
  plan, no error, and an answer box that would have failed the same way. The
  cause was a missing `ANTHROPIC_API_KEY` on prod, so every `shape/2` errored;
  the guided intake had been dead at its first turn for 25 days.

  The missing key is a deployment fault and gets fixed by setting it. This is
  about the other half: that failure was invisible. `unavailable/1` put a flash,
  and a flash renders above a page a phone has already scrolled past, so the
  only sign anything had happened was off screen.

  The conversation is the product here. When it cannot continue, that belongs in
  the conversation.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpec.Intake

  defmodule FailingShaper do
    @moduledoc false
    @behaviour CodeMySpec.Intake.Shaper

    @impl true
    def shape(_plan, _turns), do: {:error, :no_api_key}

    @impl true
    def conclude(_plan, _turns), do: {:error, :no_api_key}
  end

  setup do
    previous = Application.get_env(:code_my_spec, Intake, [])

    Application.put_env(
      :code_my_spec,
      Intake,
      Keyword.put(previous, :shaper, FailingShaper)
    )

    on_exit(fn -> Application.put_env(:code_my_spec, Intake, previous) end)
    :ok
  end

  test "the visitor is told, in the conversation", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    html =
      view
      |> form("form[phx-submit=describe]", %{description: "an AI mahjong coach for beginners"})
      |> render_submit()

    assert html =~ ~s(data-test="intake-trouble"),
           "the model failed and the conversation says nothing about it. The visitor " <>
             "sees their own answer and then a box that will fail again — which is " <>
             "indistinguishable from the page having stopped, and is exactly how this " <>
             "went unnoticed in production for 25 days."

    assert html =~ "another go", "the message should say what to do, not just that it failed"
  end

  test "their answer is still there, and so is the box", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    html =
      view
      |> form("form[phx-submit=describe]", %{description: "an AI mahjong coach for beginners"})
      |> render_submit()

    assert html =~ "an AI mahjong coach for beginners",
           "a failed turn threw away what the visitor had already typed"

    assert html =~ ~s(phx-submit="answer"),
           "there is no way to try again — retrying is the right move here and the " <>
             "message tells them to"
  end

  test "and the trouble clears when the next attempt starts", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    view
    |> form("form[phx-submit=describe]", %{description: "an AI mahjong coach for beginners"})
    |> render_submit()

    # Let it work this time. Trouble that outlives the failure it describes is
    # its own lie, and a stale error on a working turn is worse than none.
    Application.put_env(
      :code_my_spec,
      Intake,
      Keyword.put(
        Application.get_env(:code_my_spec, Intake, []),
        :shaper,
        CodeMySpec.Intake.Shaper.Scripted
      )
    )

    html =
      view
      |> form("form[phx-submit=answer]", %{answer: "beginners learning to play"})
      |> render_submit()

    refute html =~ ~s(data-test="intake-trouble"),
           "the previous turn's failure is still on screen after a turn that worked"
  end
end
