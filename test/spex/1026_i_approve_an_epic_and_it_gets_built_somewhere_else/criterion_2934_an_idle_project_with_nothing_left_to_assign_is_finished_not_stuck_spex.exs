defmodule CodeMySpecSpex.Story964.Criterion2934Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2934 — An idle project with nothing left to assign is finished, not
  stuck.

  Rule: The main agent has work to assign only when nothing is in progress and
  unassigned work exists.

  The other half, and the one that decides what an untouched project reports
  overnight. Idle-and-finished and idle-with-work-waiting are both "nothing is
  happening", and only the second wants anybody to act. A node that cannot tell
  them apart either nags a finished project forever or goes quiet on one that is
  waiting for a push.

  The node is satisfied here for the opposite reason to 2933: not because
  something is underway, but because there is nothing left to hand out.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent has work to assign only when nothing is in progress and unassigned work exists" do
    scenario "An idle project with nothing left to assign is finished, not stuck" do
      given_ "a project with no work in progress", context do
        {:ok, _live, copies} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute copies =~ "data-test=\"agent-chip\"",
               "something is running, so idle is not the premise"

        {:ok, context}
      end

      given_ "and no unassigned stories", context do
        {:ok, _live, stories} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        refute stories =~ "data-test=\"story-row\"",
               "the project has stories, so there may be work left to assign and this " <>
                 "would be testing the other case"

        {:ok, context}
      end

      when_ "the main agent asks whether it has work to assign", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/requirements")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the answer is no, and the reason is that there is nothing left", context do
        assert context.html =~ ~r/data-requirement="work_dispatched"[^>]*data-satisfied="true"/,
               "a project with nothing to assign reports work to assign, so it nags " <>
                 "forever about work that does not exist"

        {:ok, context}
      end

      then_ "and that reads differently from idle-with-work-waiting", context do
        assert context.html =~ ~r/data-requirement="work_dispatched"[^>]*data-basis="[^"]+"/,
               "the node says satisfied and does not say why. Nothing-in-progress and " <>
                 "nothing-left-to-assign are both 'no work to assign' and only one of " <>
                 "them means the project is done — a screen that cannot tell them apart " <>
                 "reports a finished project the same way as a stalled one."

        {:ok, context}
      end
    end
  end
end
