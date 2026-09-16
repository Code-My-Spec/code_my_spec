defmodule CodeMySpecSpex.Story964.Criterion2931Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2931 — A proposal I ignore changes nothing.

  Rule: Starting development on an epic happens only after the user agrees to
  it.

  The failure path, and the one that costs money if it is wrong. A gate that
  starts work when you do not answer is not a gate — it is a delay. Somebody who
  walks away from the screen must come back to exactly what they left: no
  checkout minted, no epic sent, no agent burning a subscription on work they
  had not agreed to.

  Deliberately not "and it times out after an hour". John: *"I think we stick
  with the approval to start with."*
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Starting development on an epic happens only after the user agrees to it" do
    scenario "A proposal I ignore changes nothing" do
      given_ :synced_context_component

      given_ "the main agent has proposed an epic", context do
        epic = EpicHelpers.propose(context, "Something it would like to build", stories: 3)

        {:ok, Map.put(context, :epic, epic)}
      end

      when_ "I do not answer", context do
        # Nothing. That is the whole of the when — the absence of an act is what
        # the criterion is about, and anything done here would be answering.
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "no epic is sent and no working copy is made", context do
        refute context.html =~ "data-epic-status=\"dispatched\"",
               "the epic dispatched itself. A gate that starts work when nobody answers " <>
                 "is a delay, not a gate."

        refute context.html =~ "data-test=\"epic-working-copy\"",
               "a working copy was made for an epic nobody agreed to"

        {:ok, context}
      end

      then_ "and no agent is started", context do
        {:ok, _live, copies} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute copies =~ "data-test=\"agent-chip\"",
               "an agent is running against a proposal I ignored, so walking away from " <>
                 "the screen spends money on work I never agreed to"

        {:ok, context}
      end
    end
  end
end
