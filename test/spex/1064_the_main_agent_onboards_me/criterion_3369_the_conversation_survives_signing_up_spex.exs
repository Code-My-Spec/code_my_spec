defmodule CodeMySpecSpex.Story1064.Criterion3369Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3369 — What a visitor said before they had an account is still
  there after they make one, and nobody asks them for it twice.

  ## Why this one has no login setup

  Every other spex in this project opens with
  `setup :register_log_in_setup_account`, and using it here would delete the
  premise: the criterion is about somebody who has *not* signed up yet. The
  visitor has to arrive anonymous, say something, and only then register —
  which is why this drives `/build` on a bare `build_conn/0` and registers
  through the real form rather than arriving already authenticated.

  The plan is keyed on an anonymous session token minted by
  `CodeMySpecWeb.Plugs.IntakeSession` before the LiveView mounts, and the whole
  question here is whether that survives the one moment the browser gains a
  user. Signing up is the event most likely to lose it, because it is where the
  session is rewritten.

  ## What "not asked it again" means as an assertion

  The criterion has two halves and the second is the one that can pass falsely.
  A page could carry the old description forward *and* still put the same
  question back in front of them, which satisfies "it is still in it" and fails
  the story. So the second `then_` asserts the description is present as
  content rather than as an empty prompt waiting to be filled.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @description "a booking tool for a two-chair barbershop"

  spex "a visitor who described their idea before signing up" do
    scenario "The conversation survives signing up" do
      given_ "a visitor has been telling the agent what they want to build", context do
        conn = Phoenix.ConnTest.build_conn()

        {:ok, plan_live, _html} = live(conn, "/build")

        plan_live
        |> form("[data-test='intake-composer']", description: @description)
        |> render_submit()

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:plan_live, plan_live)}
      end

      when_ "they sign up", context do
        {:ok, registration_live, _html} = live(context.conn, "/users/register")

        email = "barber-#{System.unique_integer([:positive])}@example.com"

        registration_live
        |> form("#registration_form", user: %{email: email})
        |> render_submit()

        {:ok, Map.put(context, :email, email)}
      end

      then_ "the same conversation carries on, with what they already said still in it",
            context do
        {:ok, _live, html} = live(context.conn, "/build")

        assert html =~ @description,
               """
               What the visitor said before signing up is gone. The plan is keyed
               on the anonymous session token, and registration is where the
               session is rewritten — so this is the one moment it can be lost.
               """

        {:ok, context}
      end

      and_ "they are not asked it again", context do
        {:ok, live, _html} = live(context.conn, "/build")

        refute has_element?(live, "[data-test='intake-composer'][phx-submit='describe']"),
               """
               The visitor is being asked to describe what they are building, having
               already described it — the composer is still submitting `describe`
               rather than moving on. Carrying the text forward and re-asking the
               question satisfies the first half of this criterion and fails the
               story.
               """

        {:ok, context}
      end
    end
  end
end
