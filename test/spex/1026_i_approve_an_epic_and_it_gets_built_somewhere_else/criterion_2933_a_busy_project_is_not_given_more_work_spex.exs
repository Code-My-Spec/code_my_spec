defmodule CodeMySpecSpex.Story964.Criterion2933Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2933 — A busy project is not given more work.

  Rule: The main agent has work to assign only when nothing is in progress and
  unassigned work exists.

  John started at "have all the stories and epics been assigned out" and
  corrected himself to something better:

  > "maybe the condition is actually that there is no ongoing work, so none of
  > the working copies are in progress, and there is no unassigned work ... if
  > an agent is working on our story, the main agent doesn't need to assign more
  > work."

  Act-when-idle rather than assign-everything. This is the half that stops the
  main agent piling epics onto copies that are already busy.

  ## The surface

  This is the graph node John described — *"just another note on the graph"* —
  so the question is asked the way the main agent asks every other one: of the
  project's requirements. `work_dispatched` is unsatisfied only when there is
  something to do about it.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent has work to assign only when nothing is in progress and unassigned work exists" do
    scenario "A busy project is not given more work" do
      given_ :synced_context_component

      given_ "an epic already being built on a working copy", context do
        context = EpicHelpers.dispatch_one(context, "Already underway", stories: 2)

        {:ok, context}
      end

      given_ "and more ready stories nobody has been given", context do
        StoryHelpers.create_and_link(context.scope, context.component.module_name,
          title: "Waiting its turn",
          description: "Ready, and nobody has it",
          acceptance_criteria: ["It works"]
        )

        {:ok, context}
      end

      when_ "the main agent asks whether it has work to assign", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/requirements")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the answer is no, because something is already in progress", context do
        assert context.html =~ ~r/data-requirement="work_dispatched"[^>]*data-satisfied="true"/,
               "the project reports work to assign while an epic is already being built. " <>
                 "If an agent is working on our story the main agent does not need to " <>
                 "assign more, and the alternative is epics piled onto a copy that is busy."

        {:ok, context}
      end
    end
  end
end
