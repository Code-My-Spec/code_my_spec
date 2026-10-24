defmodule CodeMySpecSpex.Story1141.Criterion2362Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2362 — Sam's run finishes.

  When the last test finishes the run reads as finished, with its totals:
  three tests, one failure.
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

  spex "Sam's run finishes", criterion: 2362 do
    scenario "the held test is released and the suite ends" do
      given_ "Sam's suite is running", context do
        {:ok, LiveRun.start(context)}
      end

      when_ "the last test finishes", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        :ok = ClusteredProject.release(context.harness.root)
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees the run finished, with its totals", context do
        eventually(
          fn ->
            html = render(context.view)
            assert html =~ ~r/finished/i, "the run does not read as finished"
            assert html =~ ~r/3 tests/
            assert html =~ ~r/1 failure/
          end,
          60_000
        )

        {:ok, context}
      end
    end
  end
end
