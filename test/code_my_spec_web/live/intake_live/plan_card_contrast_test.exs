defmodule CodeMySpecWeb.IntakeLive.PlanCardContrastTest do
  @moduledoc """
  Every field on the plan card states its own text colour.

  daisyUI's `.input` and `.select` set their own background —
  `--color-base-100` — and no colour, so they inherit it from whatever encloses
  them. On the plan card that is `.chat-bubble-neutral`, which sets
  `--color-neutral-content`: the colour meant to sit on the dark neutral bubble.

  In dark mode those happen to agree. In light mode base-100 is white and
  neutral-content is near-white, so the plan card — the one screen where the
  visitor confirms what actually gets built — was white on white and unreadable.
  Reported from a phone; every screenshot taken while building it was dark.

  Asserted on the markup because there is no way to assert on the rendering: the
  colours resolve in the browser, from CSS variables, per theme. What is
  checkable here is the thing that was missing — a control inside a coloured
  bubble that never says what colour its own text is.
  """
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpec.Intake

  defmodule StraightToPlan do
    @moduledoc false
    @behaviour CodeMySpec.Intake.Shaper

    @impl true
    def shape(_plan, _turns), do: {:ok, answers()}

    @impl true
    def conclude(_plan, _turns), do: {:ok, answers()}

    defp answers,
      do: %{needs_sign_in: false, separate_copies: false, who_uses: "beginners"}
  end

  setup do
    previous = Application.get_env(:code_my_spec, Intake, [])
    Application.put_env(:code_my_spec, Intake, Keyword.put(previous, :shaper, StraightToPlan))
    on_exit(fn -> Application.put_env(:code_my_spec, Intake, previous) end)
    :ok
  end

  test "no field on the plan card leaves its colour to the bubble", %{conn: conn} do
    conn = get(conn, "/build")
    {:ok, view, _html} = live(conn)

    html =
      view
      |> form("form[phx-submit=describe]", %{description: "a mahjong game with an ai coach"})
      |> render_submit()

    assert html =~ ~s(data-test="intake-plan"), "the plan card did not render"

    controls =
      Regex.scan(~r/<(?:input|select)\b[^>]*class="([^"]*)"[^>]*>/, html)
      |> Enum.map(fn [_, classes] -> classes end)
      |> Enum.filter(&(String.contains?(&1, "input") or String.contains?(&1, "select")))

    assert controls != [], "found no fields on the plan card to check"

    inheriting = Enum.reject(controls, &String.contains?(&1, "text-"))

    assert inheriting == [],
           """
           These plan-card fields state no text colour, so they inherit it from
           `.chat-bubble-neutral` while drawing themselves on `--color-base-100`:

               #{Enum.join(inheriting, "\n    ")}

           In light mode that is near-white text on a white field. This is the
           screen where the visitor confirms what gets built.
           """
  end
end
