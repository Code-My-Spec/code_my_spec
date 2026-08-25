defmodule CodeMySpecSpex.Story964.Criterion2941Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2941 — An idle project with work waiting gets an epic put in front
  of me.

  Rule: The main agent sending an epic for approval and the user approving it
  are two separate acts.

  The state 2933 and 2934 exist to isolate: nothing in progress *and* work
  waiting. This is what happens in it.

  John: *"if there are unassigned epics and no agents are working we should be
  promoting the main agent to get things moving. It means the agent gets the
  next epic ready to release for work and sends the approval. The agent sending
  it and the meatbags approving it are two different things."*

  So the node never assigns anything. It makes the agent prepare and send; the
  approval is still a person's. That keeps the gate and stops a project sitting
  still because nobody remembered to look.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent sending an epic for approval and the user approving it are two separate acts" do
    scenario "An idle project with work waiting gets an epic put in front of me" do
      given_ :synced_context_component

      given_ "no agents working and unassigned stories waiting", context do
        StoryHelpers.create_and_link(context.scope, context.component.module_name,
          title: "Waiting for somebody to pick it up",
          description: "Ready, unassigned, and nothing is running",
          acceptance_criteria: ["It works"]
        )

        {:ok, _live, copies} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute copies =~ "data-test=\"agent-chip\"",
               "something is running, so this is not the idle-with-work state"

        {:ok, context}
      end

      when_ "the main agent notices", context do
        # The node is what makes it notice. Asking is how the agent finds out it
        # has something to do, and acting on it is the next step rather than
        # something that happens invisibly.
        {:ok, _live, requirements} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/requirements")

        epic = EpicHelpers.propose(context, "The next set to build", stories: 1)

        {:ok, context |> Map.put(:requirements, requirements) |> Map.put(:epic, epic)}
      end

      then_ "the node said there was work to assign", context do
        assert context.requirements =~
                 ~r/data-requirement="work_dispatched"[^>]*data-satisfied="false"/,
               "nothing in progress and work waiting is the one state that wants somebody " <>
                 "to act, and the node reported nothing to do"

        {:ok, context}
      end

      then_ "and an epic is sent for approval rather than started", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        assert html =~ "data-epic-status=\"proposed\"",
               "no epic was put in front of me"

        refute html =~ "data-epic-status=\"dispatched\"",
               "the agent assigned the work itself. Sending and approving are two acts, " <>
                 "and collapsing them removes the gate John kept."

        {:ok, context}
      end
    end
  end
end
