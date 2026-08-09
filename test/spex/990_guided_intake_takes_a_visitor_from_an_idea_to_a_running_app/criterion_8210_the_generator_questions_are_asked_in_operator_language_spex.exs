defmodule CodeMySpecSpex.Story990.Criterion8210Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8210 — The shaping questions come one at a time, in operator language.

  Rule: the visitor is asked about sign-in and separate copies one question at
  a time, in operator language.

  These two answers are the generator's inputs, so a wrong one costs the
  visitor the app they get. "Do you want accounts?" gets a yes from someone
  who means logins and a yes from someone who means tenancy, and neither of
  them is answering the question we asked. Asking in the visitor's own terms
  is what makes the answer worth acting on.

  One at a time is the half this spec used to miss. It asserted both questions
  appeared in the same render, which a page of dropdowns satisfies — and that
  is what got built. A conversation can take account of what was just said; a
  form cannot, and asks the same three fields of everyone.

  Surface: the `/build` LiveView, driven anonymously.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @sign_in ~r/sign in to use this/i
  @copies ~r/separate businesses each use their own copy/i

  spex "The shaping questions are asked one at a time, in operator language" do
    scenario "The shaping questions come one at a time, in operator language" do
      given_ "a visitor who has described what they want to build", context do
        {:ok, view, _html} = live(build_conn(), "/build")

        html =
          view
          |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
          |> render_submit()

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "they are asked one question, not handed a page of them", context do
        asked = Enum.count([@sign_in, @copies], &(context.html =~ &1))

        assert asked == 1,
               "expected exactly one shaping question on screen, found #{asked} — " <>
                 "a visitor handed both at once is filling in a form, not answering a question"

        {:ok, context}
      end

      when_ "they answer the question they were asked", context do
        html =
          context.view
          |> form("form[phx-submit=answer]", %{answer: "yes"})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the next question is the one they had not been asked yet", context do
        assert context.html =~ @copies,
               "expected the tenancy question once the first was answered, got: #{context.html}"

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
