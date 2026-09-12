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

  ## Two ways this scenario can lie, and what stops each

  `live/2` runs the request and throws the resulting conn away, so the intake
  token is minted afresh on every call and each step is a different visitor.
  A scenario written that way reports that the conversation was lost no matter
  what the product does — which is what this one reported until the conn from
  `get/2` was threaded through. The failure is indistinguishable from the real
  defect, and it is the more likely of the two.

  The opposite lie is passing without going near the risk. Registering only
  sends the login link; the session is rewritten when the link is *followed*,
  in `UserAuth.log_in_user/3`. So this reads the link out of the email the
  visitor actually receives and follows it. Blinded — swapping the final mount
  onto a fresh conn — the scenario goes red, which is how the assertion is
  known to be measuring the session rather than the page.

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
        # `live/2` runs the request and discards the resulting conn, so the
        # intake token `Plugs.IntakeSession` mints on the way in would be
        # minted afresh on every later call and this would be a series of
        # strangers rather than one visitor. Holding the conn from `get/2` is
        # what makes the rest of this scenario about the same person.
        conn = get(Phoenix.ConnTest.build_conn(), "/build")

        {:ok, plan_live, _html} = live(conn)

        plan_live
        |> form("[data-test='intake-composer']", description: @description)
        |> render_submit()

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:plan_live, plan_live)}
      end

      when_ "they sign up", context do
        conn = get(context.conn, "/users/register")
        {:ok, registration_live, _html} = live(conn)

        email = "barber-#{System.unique_integer([:positive])}@example.com"

        registration_live
        |> form("#registration_form", user: %{email: email})
        |> render_submit()

        # Registering only sends the link. The session is rewritten when the
        # link is followed — `UserAuth.log_in_user/3` renews it — so a scenario
        # that stopped at the form would never reach the moment this criterion
        # is about, and would pass for a session nothing had happened to.
        assert_received {:email, %Swoosh.Email{text_body: body}}

        [link] = Regex.run(~r{/users/log-in/[^\s\]]+}, body)

        conn = get(conn, link)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:email, email)}
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
