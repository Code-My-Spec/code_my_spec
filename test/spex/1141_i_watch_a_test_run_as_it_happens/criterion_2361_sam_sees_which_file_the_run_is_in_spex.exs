defmodule CodeMySpecSpex.Story1141.Criterion2361Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2361 — Sam sees which file the run is in.

  The run shows the file it is running now: the held file, once the others
  have reported.
  """

  # A real suite on a live harness, run while this scenario watches.
  use CodeMySpecSpex.Case, async: false

  import Phoenix.LiveViewTest

  alias CmsHarnessTest.ClusteredProject
  alias CodeMySpecSpex.LiveRun
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Sam sees which file the run is in", criterion: 2361 do
    scenario "the run is on the held file" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "the run moves on to the next test file", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees that file as the one running now", context do
        eventually(
          fn ->
            assert render(context.view) =~ ClusteredProject.held_file(),
                   "the page does not name the file the run is in"
          end,
          30_000
        )

        {:ok, context}
      end
    end
  end
end
