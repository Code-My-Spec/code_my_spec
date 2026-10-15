defmodule CodeMySpecSpex.Story1064.Criterion2204Spex do
  @moduledoc """
  Story 1064 — The product agent onboards me
  Criterion 2204 — While the onboarding questions are still being asked and no
  project exists yet, the main agent does not ask any of them or write into
  the form.

  ## The negative half of the same rule as 2202/2203

  2202 and 2203 together say the product agent runs onboarding and main only
  takes over once the project exists; this is the same rule stated as what
  must *not* happen in between. There is no project yet while this fires, so
  there is no `/app/projects/:id/agent-conversation` to visit at all — the
  only page in play is `/build`, which this checks for the absence of
  anything identifying main as a participant in it: no `main-agent` marker
  (the same one 2203 checks *for*), and no turn in the transcript labelled
  with main's role rather than product's.

  The `when_` step carries no action of its own — "the project does not exist
  yet" is the condition under which the prior given holds, not a thing
  somebody does — so it passes `context` through unchanged, as a `then_`
  that only asserts is allowed to.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "somebody is part-way through the onboarding questions and the project does not exist yet",
    criterion: 2204 do
    scenario "Main does not run the onboarding interview" do
      given_ "somebody is part-way through the onboarding questions", context do
        conn = get(Phoenix.ConnTest.build_conn(), "/build")
        {:ok, live, _html} = live(conn)

        describe_idea(live, "a booking tool for a two-chair barbershop")

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "the project does not exist yet", context do
        {:ok, context}
      end

      then_ "the main agent does not ask onboarding questions", context do
        refute has_element?(context.live, "[data-test='main-agent']"),
               "the main agent's own marker is on a page with no project to be main of"

        {:ok, context}
      end

      and_ "or write into the form", context do
        refute has_element?(
                 context.live,
                 "[data-test='intake-said'][data-from='agent'] [data-test='message'][data-agent-role='main']"
               ),
               """
               A turn in the transcript is labelled as main's rather than the
               product agent's, with no project for main to be the main agent
               of yet.
               """

        {:ok, context}
      end
    end
  end
end
