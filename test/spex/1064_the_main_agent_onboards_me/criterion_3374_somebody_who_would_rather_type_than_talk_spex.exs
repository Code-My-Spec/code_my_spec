defmodule CodeMySpecSpex.Story1064.Criterion3374Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3374 — Somebody who would rather fill the form in than discuss it
  can do that, and is set up without having waited on the agent at all.

  ## Known red, and what it is waiting for

  There is no form to fill in until the conversation has produced one. The plan
  card renders on `@plan.status in [:planned, :converted]`, and a plan opens at
  `:describing` and only reaches `:planned` when the shaper concludes — so the
  paperwork is downstream of the talking rather than beside it, and this person
  has no way in.

  That is the gap the story names: "What does not exist, on either side of the
  product, is those fields as an **editable form**." Seven of this story's nine
  criteria already pass against the intake funnel; this one and 3375 are the two
  that need the form to exist independently of the conversation, and they are
  red together for that single reason.

  ## Why this is a criterion and not a preference

  The story's own framing is that the conversation is the sales process. Someone
  who would rather type is not refusing the product — they are the visitor most
  certain of what they want, and making them talk their way to a form they could
  have filled in is the one interaction that turns the agent from help into a
  toll gate.

  ## "Having waited on nothing" is asserted on arrival

  Not by timing anything. The claim is structural: if the form is on the page
  the moment they arrive, they waited on nothing, and if it is not there until
  the agent has concluded, they waited however long that took. So the assertion
  is that the form is present before a single turn exists — which is also the
  one reading that cannot be satisfied by making the agent faster.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "somebody would rather fill the form in than discuss it" do
    scenario "Somebody who would rather type than talk" do
      given_ "somebody would rather fill the form in than discuss it", context do
        # From `get/2`, so the intake token minted on the way in survives to the
        # step that follows where they landed.
        conn = get(context.conn, "/build")
        {:ok, live, _html} = live(conn)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "they complete it themselves", context do
        assert has_element?(context.live, "form[phx-submit=confirm_names]"),
               """
               There is nothing to fill in. The plan card renders only once the
               shaper has concluded, so the paperwork is downstream of the talking
               rather than beside it — and somebody who would rather type has no
               way in at all.

               This is the gap the story names: the intake fields do not exist as
               an editable form independent of the conversation.
               """

        refute has_element?(context.live, "[data-test='intake-said']"),
               """
               They have waited on the agent after all: there is already
               conversation on the page. "Having waited on nothing" is the half of
               this criterion that a faster agent cannot satisfy.
               """

        destination =
          confirm_plan(context.live, %{
            account_name: "Kirby & Sons",
            project_name: "BarberBook",
            location: "local"
          })

        {:ok, Map.put(context, :destination, destination)}
      end

      then_ "they are set up", context do
        assert is_binary(context.destination),
               "completing the form left them on it — nothing was set up"

        {:ok, live, _html} = live(context.conn, context.destination)

        assert has_element?(live, "[data-test='local-instructions']"),
               """
               They filled everything in and arrived somewhere with nothing of
               theirs on it. Being set up means the project exists and they can
               see it.
               """

        {:ok, Map.put(context, :live, live)}
      end
    end
  end
end
