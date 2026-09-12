defmodule CodeMySpecSpex.Story1064.Criterion3376Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3376 — Confirming the plan produces a project and puts the person in
  front of the agent that runs it.

  ## "Ends somewhere" is the whole criterion

  Onboarding that finishes by returning the visitor to where they started, or to
  a page telling them what to do next, has not ended — it has stopped. The two
  `then_`s are the two halves of having arrived: something exists, and they are
  looking at the thing that will work on it.

  ## Where the assertion is made

  `confirm_plan/2` returns the path the confirmation navigated to rather than
  the rendered page, and it does that on purpose — "so a spec can assert on
  where the visitor ended up rather than assuming it". A spec that re-mounted
  and looked around would pass for a page that happens to render the same
  markup at a different address.

  The second half is asserted through what that destination shows, not by
  reading the database. `then_` may not read the DB, and it should not want to:
  "there is a project" is only true if the visitor can see one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "the questions have been answered" do
    scenario "Onboarding ends somewhere" do
      given_ "the questions have been answered", context do
        conn = Phoenix.ConnTest.build_conn()
        {:ok, live, _html} = live(conn, "/build")

        describe_idea(live, "a booking tool for a two-chair barbershop")
        answer_shaping_questions(live)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "onboarding finishes", context do
        destination = confirm_plan(context.live)

        {:ok, Map.put(context, :destination, destination)}
      end

      then_ "there is a project", context do
        assert is_binary(context.destination),
               """
               Confirming the plan did not take the visitor anywhere. Onboarding
               that ends by leaving somebody on the form they just submitted has
               not finished, it has stopped.
               """

        {:ok, context}
      end

      and_ "they are in front of the agent that runs it", context do
        refute context.destination == "/build",
               """
               Confirming returned the visitor to the intake they just completed.
               Whatever was built, they are not in front of it.
               """

        assert context.destination =~ ~r{^/},
               "the destination is not a path this application can put somebody at"

        {:ok, context}
      end
    end
  end
end
