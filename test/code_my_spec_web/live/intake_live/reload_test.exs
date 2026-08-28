defmodule CodeMySpecWeb.IntakeLive.ReloadTest do
  @moduledoc """
  Reloading restores the conversation. It does not hold it again.

  The turns and the pending question lived in socket assigns, so a reload kept
  the plan row and lost the conversation — the visitor came back to their own
  description and an empty answer box.

  The first fix for that re-asked the model on mount, which was worse in a way
  that took a report to see: with no turns to send, the model was asked the same
  first message again and answered differently, so every reload silently
  replaced the question with a new one. Reported as "it made the call a second
  time from the first message and returned a different response. Every time it
  reloads it does the same call again."

  Restoring is the only version of this that is free and stable. The counter
  here is the point: a reload must cost zero model calls.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpec.Intake

  defmodule CountingShaper do
    @moduledoc false
    @behaviour CodeMySpec.Intake.Shaper

    @impl true
    def shape(_plan, turns) do
      count = :counters.get(counter(), 1) + 1
      :counters.put(counter(), 1, count)
      {:ask, "question number #{count}, asked with #{length(turns)} turn(s)"}
    end

    @impl true
    def conclude(_plan, _turns), do: {:ok, %{needs_sign_in: false, separate_copies: false}}

    def counter do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil ->
          ref = :counters.new(1, [])
          :persistent_term.put({__MODULE__, :counter}, ref)
          ref

        ref ->
          ref
      end
    end

    def calls, do: :counters.get(counter(), 1)
    def reset, do: :counters.put(counter(), 1, 0)
  end

  setup do
    previous = Application.get_env(:code_my_spec, Intake, [])
    Application.put_env(:code_my_spec, Intake, Keyword.put(previous, :shaper, CountingShaper))
    CountingShaper.reset()
    on_exit(fn -> Application.put_env(:code_my_spec, Intake, previous) end)
    :ok
  end

  test "a reload costs no model call and shows the same question", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    first =
      view
      |> form("form[phx-submit=describe]", %{description: "a mahjong game with an ai coach"})
      |> render_submit()

    assert CountingShaper.calls() == 1
    assert first =~ "question number 1"

    {:ok, _reloaded, html} = live(conn, "/build")

    assert CountingShaper.calls() == 1,
           "the reload asked the model again. With no turns to send it asks the same " <>
             "first message and gets a different answer, so the question the visitor " <>
             "was reading is silently replaced — every reload, forever."

    assert html =~ "question number 1",
           "the reload rendered a different question than the one on screen"
  end

  test "an answered turn is on the row, so the next question sees it", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    view
    |> form("form[phx-submit=describe]", %{description: "a mahjong game with an ai coach"})
    |> render_submit()

    html =
      view
      |> form("form[phx-submit=answer]", %{answer: "beginners learning to play"})
      |> render_submit()

    assert html =~ "asked with 1 turn(s)",
           "the second question was asked with no history, so the conversation is " <>
             "starting over on every turn rather than building"

    # And it survives the reload too.
    {:ok, _reloaded, reloaded_html} = live(conn, "/build")
    assert reloaded_html =~ "beginners learning to play", "the answer was not kept"
    assert reloaded_html =~ "asked with 1 turn(s)"
  end
end
