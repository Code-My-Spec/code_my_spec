defmodule CodeMySpecSpex.Story964.Criterion2930Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2930 — A working copy is made only after I agree.

  Rule: Starting development on an epic happens only after the user agrees to
  it.

  The happy path of the gate. Agreeing is the whole of what starts work: after
  it there is somewhere for the epic to be built and an agent building it, and I
  did not choose a checkout or start anything, because knowing which checkout
  anything is in is what story 963 exists to spare a non-technical user.

  Where it runs is the agent's call — John: *"if an existing working copy and
  agent is appropriate it gets assigned there, or a fresh one at the agent's
  discretion."* So this asserts that the epic ends up on a copy, not which one.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Starting development on an epic happens only after the user agrees to it" do
    scenario "A working copy is made only after I agree" do
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

      then_ "the epic is on a working copy with an agent on it", context do
        assert context.html =~ "data-epic-status=\"dispatched\"",
               "agreeing did not dispatch the epic"

        assert context.html =~ "data-test=\"epic-working-copy\"",
               "the epic is dispatched and names no working copy, so there is nowhere " <>
                 "the work is actually happening"

        {:ok, context}
      end

      then_ "and I did not choose a checkout or start anything", context do
        refute context.html =~ "data-test=\"choose-working-copy\"",
               "I was asked which checkout to use. Knowing which checkout anything is in " <>
                 "is exactly what a non-technical user should not have to hold, and where " <>
                 "it runs is the agent's call."

        {:ok, context}
      end
    end
  end
end
