defmodule CodeMySpecSpex.Story1144.Criterion2376Spex do
  @moduledoc """
  Story 1144 — Credo findings arrive as credo finds them.
  Criterion 2376 — Sam's credo run finishes.

  When credo has checked every file the run reads as finished, with its
  totals: one file, one finding.
  """

  # Credo running for real on a live harness, watched while it runs.
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

  spex "Sam's credo run finishes", criterion: 2376 do
    scenario "the held check is released and credo ends" do
      given_ "credo is running on Sam's project", context do
        {:ok, LiveRun.start_credo(context)}
      end

      when_ "it has checked every file", context do
        {:ok, view, _html} = live(context.conn, LiveRun.path(context))
        :ok = ClusteredProject.release(context.harness.root)
        {:ok, Map.put(context, :view, view)}
      end

      then_ "Sam sees the run finished, with its totals", context do
        eventually(
          fn ->
            html = render(context.view)
            assert html =~ ~r/finished/i, "the run does not read as finished"
            assert html =~ ~r/1 file\b/
            assert html =~ ~r/1 finding\b/
          end,
          60_000
        )

        {:ok, context}
      end
    end
  end
end
