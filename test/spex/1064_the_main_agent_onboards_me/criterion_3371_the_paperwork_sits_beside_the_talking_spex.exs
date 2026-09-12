defmodule CodeMySpecSpex.Story1064.Criterion3371Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3371 — What gets settled in the conversation shows up in the form
  next to it, without the visitor being sent anywhere to put it there.

  ## The second half is the one with teeth

  "It appears in the form" is easy to satisfy. "They were never sent to another
  page to put it there" is the claim that shapes the product, and it is why the
  form lives inside the transcript rather than on a page of its own.

  So this asserts both, and asserts the second as a fact about where the visitor
  is rather than about how the page looks: `live/2` returns a redirect tuple
  instead of a view when a LiveView sends somebody elsewhere, so settling an
  answer must leave them on `/build`.

  ## Driven through the shared steps, deliberately

  `CodeMySpecSpex.IntakeSteps` exists because specs used to post three form
  values in one go, "which is how a page of dropdowns survived a rule that never
  sanctioned it — every spec agreed with the implementation because each was
  written against it". Answering in sentences is the visitor's actual action;
  how many questions get asked is the shaper's business and not this spec's.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @description "a booking tool for a two-chair barbershop"

  spex "the agent is asking what they are building" do
    scenario "The paperwork sits beside the talking" do
      given_ "the agent is asking what they are building", context do
        # From `get/2` rather than `live/2`, which discards the conn it built.
        # The last step re-mounts `/build`, and on a fresh conn that would be a
        # stranger arriving — never redirected, whatever happened to the person
        # this scenario is about.
        conn = get(Phoenix.ConnTest.build_conn(), "/build")
        {:ok, live, _html} = live(conn)

        describe_idea(live, @description)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "an answer is settled", context do
        html = answer_shaping_questions(context.live)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it appears in the form beside the conversation", context do
        assert has_element?(
                 context.live,
                 "[data-test='intake-plan'] form[phx-submit=confirm_names]"
               ),
               """
               There is no form inside the conversation. What the agent settled has
               to land somewhere the visitor can see and correct, next to the
               talking rather than instead of it.
               """

        assert has_element?(context.live, "[data-test='intake-transcript']"),
               "the conversation is gone — the form replaced it rather than joining it"

        {:ok, context}
      end

      and_ "they were never sent to another page to put it there", context do
        assert {:ok, _live, _html} = live(context.conn, "/build"),
               """
               Settling an answer moved the visitor off /build. `live/2` answers a
               redirect tuple rather than a view when a LiveView sends somebody
               elsewhere, so this is the whole of "never sent to another page".
               """

        {:ok, context}
      end
    end
  end
end
