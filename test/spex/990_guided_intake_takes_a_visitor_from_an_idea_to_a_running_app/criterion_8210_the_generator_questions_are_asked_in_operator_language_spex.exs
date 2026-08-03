defmodule CodeMySpecSpex.Story990.Criterion8210Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8210 — The generator questions are asked in operator language.

  Rule: the plan asks about sign-in and separate copies in operator language,
  never in product terms.

  These two answers are the generator's inputs, so a wrong one costs the
  visitor the app they get. "Do you want accounts?" gets a yes from someone
  who means logins and a yes from someone who means tenancy, and neither of
  them is answering the question we asked. Asking in the visitor's own terms
  is what makes the answer worth acting on.

  Surface: the `/build` LiveView, driven anonymously.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "The plan asks its shaping questions in operator language" do
    scenario "The generator questions are asked in operator language" do
      given_ "a visitor who has described what they want to build", context do
        {:ok, view, _html} = live(build_conn(), "/build")

        html =
          view
          |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
          |> render_submit()

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "they are asked whether people need to sign in to use it", context do
        assert context.html =~ "sign in to use this",
               "expected the sign-in question in plain terms, got: #{context.html}"

        {:ok, context}
      end

      then_ "they are asked whether separate businesses each use their own copy", context do
        assert context.html =~ "separate businesses each use their own copy",
               "expected the tenancy question in plain terms, got: #{context.html}"

        {:ok, context}
      end

      then_ "no question uses product jargon", context do
        for jargon <- [~r/multi-?tenan/i, ~r/authentication/i, ~r/\btenancy\b/i] do
          refute context.html =~ jargon,
                 "expected no product jargon in the shaping questions, found #{inspect(jargon)}"
        end

        {:ok, context}
      end
    end
  end
end
