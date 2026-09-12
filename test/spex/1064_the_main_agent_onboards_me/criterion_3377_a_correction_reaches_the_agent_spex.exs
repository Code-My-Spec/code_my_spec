defmodule CodeMySpecSpex.Story1064.Criterion3377Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3377 — When the person fixes something the agent got wrong, what
  happens next follows the correction rather than the original guess.

  ## The failure this exists to catch

  A form can accept an edit, echo it back, and still hand the agent's own guess
  to whatever comes next — the visitor sees their correction on screen and the
  system proceeds on the thing they just fixed. That is worse than refusing the
  edit, because nothing tells them they were overruled.

  So the assertion is deliberately *downstream* of the form. That a field holds
  the new value would only prove the input works. What the criterion claims is
  that the correction reached the agent, and the only evidence of that is what
  happens next.

  ## Why the project name

  The plan card carries five fields, and `project_name` is the one whose effect
  is visible without reading the database: the workspace builds the setup
  instructions out of it (`mix cms.new <project_name>`), so a correction that
  survived is legible on the page, and one that did not is equally legible.
  `needs_sign_in` and `separate_copies` are the consequential fields — the
  card's own comment calls them "the two conclusions that pick the generators" —
  but their effect is not observable through this surface, and a `then_` may not
  go to the database looking for it.

  ## Why this visitor is signed in

  Confirming sends an anonymous visitor to `/users/register` rather than to the
  workspace, so on that path there is no "next" to inspect yet. That gate is
  criterion 3369's subject, and borrowing it here would mean this spec went red
  for a reason that has nothing to do with corrections.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  @corrected "BarberBook"

  spex "the agent has filled a field in wrongly" do
    scenario "A correction reaches the agent" do
      given_ "the agent has filled a field in wrongly", context do
        # `live/2` runs the request and throws the resulting conn away, so the
        # intake token `Plugs.IntakeSession` mints on the way in is minted
        # again on every later call. Holding the conn from `get/2` is what
        # makes this one visitor rather than a series of strangers.
        conn = get(context.conn, "/build")
        {:ok, live, _html} = live(conn)

        describe_idea(live, "a booking tool for a two-chair barbershop")
        html = answer_shaping_questions(live)

        # Whatever the agent guessed, the correction below has to differ from
        # it, or this scenario proves nothing.
        refute html =~ @corrected,
               "the agent already guessed #{@corrected}, so correcting to it tests nothing"

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "the person corrects it", context do
        destination = confirm_plan(context.live, %{project_name: @corrected, location: "local"})

        {:ok, Map.put(context, :destination, destination)}
      end

      then_ "what the agent says next follows the correction", context do
        assert is_binary(context.destination),
               "the correction went nowhere — confirming did not take the visitor on"

        {:ok, live, html} = live(context.conn, context.destination)

        assert html =~ @corrected,
               """
               What came next is built on the agent's guess rather than the person's
               correction. A form that takes an edit, echoes it back, and then hands
               the original downstream is worse than one that refuses the edit —
               nothing tells the visitor they were overruled.
               """

        {:ok, Map.put(context, :live, live)}
      end
    end
  end
end
