defmodule CodeMySpecSpex.Story1064.Criterion3375Spex do
  @moduledoc """
  Story 1064 — The main agent onboards me
  Criterion 3375 — When the model is unreachable, somebody arriving to get set
  up is told so, and can still finish on their own.

  ## Known red, and what it is waiting for

  Half of this already works. The conversation says what happened —
  `IntakeLive.Plan.unavailable/1` puts the trouble into the transcript rather
  than a flash, on the reasoning that "on a phone it renders above a page the
  visitor has scrolled past, and this failure otherwise looks exactly like the
  page ending".

  The other half does not exist, for the same single reason as criterion 3374:
  there is no form until the conversation has produced one, so a visitor who
  cannot reach the agent cannot reach the paperwork either. Being told is where
  it ends for them.

  ## The comment that looks like a contradiction

  `unavailable/1` says: "No fallback questionnaire. The conversation is the
  product, so when the model is unreachable the honest thing is to say so rather
  than hand over the form it replaced."

  That is a decision about the page-based funnel this story supersedes — the
  story is explicit that it "supersedes the model they assume rather than
  retiring them outright". Under the design this story describes the form is not
  a fallback that appears when the agent fails; it is the paperwork that sits
  beside the conversation the whole time, which the agent helps fill in. A
  visitor finishing it unaided when the agent is down is that same form with
  nobody helping, not a questionnaire standing in for the product.

  Worth stating plainly because the two readings are one word apart, and the
  wrong one turns this criterion into a request to rebuild what was deliberately
  removed.

  ## Standing the model down

  Through the dev fault routes, which is what somebody testing this live has to
  use and therefore what this had better prove works. The model being
  unreachable is external system state with no surface that produces it, which
  is the case the no-fixtures rule exempts.

  It used to swap `CodeMySpec.Intake[:shaper]` for a stub, which is fine inside
  a test node and is exactly what nobody could do on the shared dev box: the
  config is node-global, so breaking the shaper to check this broke intake for
  every visitor on the machine. Issue `0fb7bf03`. The fault is keyed on the
  visitor's own session token, and the token comes back from `/dev/intake/plans`
  because `Plugs.IntakeSession` signs it into the session where no browser can
  read it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_and_log_in_user

  spex "the agent cannot be reached" do
    scenario "The agent cannot be reached" do
      given_ "the agent cannot be reached", context do
        conn = get(context.conn, "/build")
        {:ok, live, _html} = live(conn)

        # The plan this visitor is holding, found the way anybody outside the
        # application has to find it. `get/2` rather than a repository read, so
        # a route that stopped answering would fail this rather than be skipped.
        %{"plans" => [%{"session_token" => token} | _]} =
          conn |> get("/dev/intake/plans") |> json_response(200)

        %{"status" => "injected"} =
          conn
          |> post("/dev/faults", %{"key" => token, "fault" => "intake_shaper_fails"})
          |> json_response(200)

        on_exit(fn -> CodeMySpec.Faults.clear(token, :intake_shaper_fails) end)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:live, live)}
      end

      when_ "somebody arrives to get set up", context do
        describe_idea(context.live, "a booking tool for a two-chair barbershop")

        {:ok, context}
      end

      then_ "it says help is not available right now", context do
        assert has_element?(context.live, "[data-test='intake-trouble']"),
               """
               The model failed and the conversation says nothing about it. The
               visitor sees their own answer and then a box that will fail the
               same way — which is indistinguishable from the page simply ending.
               """

        {:ok, context}
      end

      and_ "the form still works", context do
        assert has_element?(context.live, "form[phx-submit=confirm_names]"),
               """
               Being told is where it ends for them. The paperwork only appears
               once the conversation has concluded, so an unreachable agent takes
               the form down with it — and somebody who came to get set up leaves
               with nothing, having been told politely.
               """

        {:ok, context}
      end

      and_ "they can finish without it", context do
        destination =
          confirm_plan(context.live, %{
            account_name: "Kirby & Sons",
            project_name: "BarberBook",
            location: "local"
          })

        assert is_binary(destination),
               "the form was on the page but would not complete without the agent"

        {:ok, live, _html} = live(context.conn, destination)

        assert has_element?(live, "[data-test='local-instructions']"),
               "they finished the form and still have no project to show for it"

        {:ok, context}
      end
    end
  end
end
