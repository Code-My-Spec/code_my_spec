defmodule CodeMySpecSpex.Story964.Criterion2932Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2932 — Ready for development is not the same as started.

  Rule: Starting development on an epic happens only after the user agrees to
  it.

  The mechanic this story is built on already half exists: `ready_for_dev` is a
  flag on a story today and nothing consumes it as a hand-off. So the first
  thing to pin down is that it stays a *judgement*, not a trigger — the main
  agent saying "these look shaped" must not be the thing that starts work, or
  the approval gate John confirmed has already been bypassed before anybody
  built it.

  ## The contract these twelve criteria fix

  An epic carries a status: `draft` → `proposed` → `dispatched`. The main agent
  moves it to `proposed` and a person moves it to `dispatched`, and those are
  the two separate acts John named — *"the agent sending it and the meatbags
  approving it are two different things."*

  On the epics screen an epic renders as `data-test="epic"` with
  `data-epic-status`, and a proposed one offers `data-test="approve-epic"`.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Starting development on an epic happens only after the user agrees to it" do
    scenario "Ready for development is not the same as started" do
      given_ :synced_context_component

      given_ "stories the main agent has marked ready for development", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Something shaped and waiting",
            description: "Marked ready, and that is all",
            acceptance_criteria: ["It works"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "I look at the project", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "nothing is being built yet", context do
        refute context.html =~ "data-epic-status=\"dispatched\"",
               "an epic is dispatched and nobody agreed to it. Ready for development is " <>
                 "the main agent's judgement that stories are shaped; treating it as a " <>
                 "trigger bypasses the approval gate before anybody has built one."

        {:ok, context}
      end

      then_ "and nothing has been spent on my behalf", context do
        {:ok, _live, copies} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute copies =~ "data-test=\"agent-chip\"",
               "an agent is running for work nobody approved"

        {:ok, context}
      end
    end
  end
end
