defmodule CodeMySpecSpex.Story990.Criterion8214Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8214 — A visitor who leaves and returns finds the plan waiting.

  Rule: an abandoned plan is still there when the visitor comes back.

  This is why the plan is a row keyed to an anonymous cookie rather than
  session state: the whole bet of guided intake is that we let people leave
  without asking for an email, which is only a bet worth making if leaving
  does not destroy what they came for. Plans never expire.

  Surface: the `/build` LiveView. The return visit is a second mount on the
  same connection, so the session cookie is carried the way a browser
  carries it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "An abandoned plan is still there when the visitor comes back" do
    scenario "A visitor who leaves and returns finds the plan waiting" do
      given_ "a visitor who reached a plan and left without signing up", context do
        # A real request first, so the session cookie exists and is carried
        # onto the return visit rather than minted fresh each time.
        conn = get(build_conn(), "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> answer_shaping_questions(["yes", "yes", "salon owners"])

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "they return to the site in the same browser", context do
        {:ok, _view, html} = live(context.conn, "/build")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "they are shown the plan they left", context do
        assert context.html =~ "what I think you&#39;re building",
               "expected the plan to be waiting, got: #{context.html}"

        {:ok, context}
      end

      then_ "the answers they had given are still as they left them", context do
        assert context.html =~ "salon owners",
               "expected their own answers to survive the return, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
