defmodule CodeMySpecSpex.Story964.Criterion3091Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3091 — I discard the copy and its agents go with it.

  Rule: A working copy is the boundary of the work: discarding it ends its
  agents and its conversation.

  John, 2026-09-04, on how he wants to control the boundaries: *"this working
  copy should be the boundary of the conversation. I wanna say like OK this is
  the working copy for the war epic and I can have those three agents in there
  and I can keep them through that whole epic and then I can discard the working
  copy and then come up with another one."*

  So the copy is the unit of lifecycle, and discarding it is the act that ends
  the work. That is what makes the boundary usable: one thing to throw away, and
  everything that belonged to that piece of work goes with it.

  The cost of getting this wrong is not tidiness. An agent that outlives the
  copy it was working in is a process with a model behind it, holding a
  subscription slot and spending on a checkout that is gone. Story 961 — "an
  agent I am done with stops, and stops consuming" — is the same concern
  arriving from the other direction.

  ## What this drives

  `offboard`, the control already on the working-copies page. It is the existing
  way a person says a copy is finished with, and this asserts what that has to
  mean once a copy carries agents.

  ## Red on purpose

  There are no agents on a copy to stop (criterion 3087), and `offboard/2`
  counts files, problems and components — not agents.
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

  spex "A working copy is the boundary of the work" do
    scenario "I discard the copy and its agents go with it" do
      given_ :synced_context_component

      given_ "a connected provider for the agents to run on", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      given_ "a working copy whose epic is finished", context do
        context = EpicHelpers.dispatch_one(context, "The war epic", stories: 1)

        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        assert html =~ ~s(data-test="agent-chip"),
               "the premise needs a copy with agents on it to discard. " <>
                 "Criterion 3087 fails first."

        {:ok, context}
      end

      when_ "I discard the copy", context do
        {:ok, live, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        html =
          live
          |> element(~s([data-test=offboard-working-copy][data-working-copy-id="#{context.copy_id}"]))
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "its three agents stop", context do
        refute context.html =~ ~s(data-test="agent-chip"),
               "the copy is gone and its agents are still listed as running. An " <>
                 "agent that outlives its checkout is a model held open against a " <>
                 "directory that is not there."

        {:ok, context}
      end

      then_ "and nothing of that work is left running", context do
        {:ok, _live, agents} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        refute agents =~ ~s(data-agent-status="running"),
               "an agent from a discarded copy is still running somewhere else on " <>
                 "the project. Discarding the copy is how the user says this work is " <>
                 "over, and it has to be the whole of it."

        {:ok, context}
      end
    end
  end
end
