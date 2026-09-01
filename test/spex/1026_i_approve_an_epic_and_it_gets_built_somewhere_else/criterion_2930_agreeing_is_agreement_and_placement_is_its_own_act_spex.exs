defmodule CodeMySpecSpex.Story964.Criterion2930Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2930 — Agreeing is agreement, and placement is its own act.

  Rule: Starting development on an epic happens only after the user agrees to
  it.

  The happy path of the gate, rewritten after John split the flow: *"I don't
  think that we should do all this when we approve the epic ... let's have these
  as separate actions — creating the working copy and assigning an epic to a
  working copy ... the user should be able to decide where to assign it, or the
  agent should be able to decide."*

  So agreeing is agreement. It is what unblocks placement and nothing more, and
  the rule above still holds exactly: nothing is built before it.

  ## What this used to say, and why the change matters

  It said "a working copy is made for that epic and an agent starts on it" — and
  nothing did, anywhere. `EpicDispatch.dispatch/2` set a status and returned;
  grepping `:dispatched` found the LiveView, the requirement checker and the
  schema, and no starter. Twelve spex passed over it because this one asserted
  that `data-epic-status="dispatched"` and `data-test="epic-working-copy"`
  render. They do. Neither is an agent.

  That is issue 28e838cc's complaint — "they assert the marker is present rather
  than what it claims" — on the criterion carrying this story's central promise.
  So this asserts the epic is agreed and placeable, which is what actually
  happens, and does not claim a starter that does not exist.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Starting development on an epic happens only after the user agrees to it" do
    scenario "Agreeing is agreement, and placement is its own act" do
      given_ :synced_context_component

      given_ "the main agent has proposed an epic of ready stories", context do
        epic = EpicHelpers.propose(context, "Five things that are ready", stories: 5)

        {:ok, live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        assert html =~ "data-test=\"approve-epic\"",
               "nothing is offered for approval, so there is nothing to agree to"

        {:ok, context |> Map.put(:epic, epic) |> Map.put(:live, live)}
      end

      when_ "I agree", context do
        html = context.live |> element("[data-test=approve-epic]") |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the epic is agreed", context do
        assert context.html =~ "data-epic-status=\"dispatched\"",
               "agreeing did not agree the epic"

        {:ok, context}
      end

      then_ "and nothing was started on my behalf", context do
        # The half the old version claimed and never checked. Placing is its own
        # act and starting is a third, so agreeing must not have produced an
        # agent — asserting the absence is the only way this criterion can be
        # wrong in the direction that matters now.
        assert Fixtures.running_agents(context.scope) == [],
               "agreeing started an agent. Under the split, agreement unblocks placement " <>
                 "and nothing else — a click that quietly starts a real agent on a real " <>
                 "subscription is the thing the separate acts exist to prevent."

        {:ok, context}
      end

      then_ "and I did not have to choose a checkout myself", context do
        refute context.html =~ "data-test=\"choose-working-copy\"",
               "I was made to choose a checkout to agree. I may choose one — that is the " <>
                 "point of the split — but being required to is what story 963 exists to " <>
                 "spare a non-technical user."

        {:ok, context}
      end
    end
  end
end
