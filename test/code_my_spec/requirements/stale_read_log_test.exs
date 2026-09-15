defmodule CodeMySpec.Requirements.StaleReadLogTest do
  @moduledoc """
  The diagnostic that makes a silent writer visible after this ships.

  Reads used to repair the graph on the way past: every entity's fingerprint
  recomputed, compared against what its rows were stamped with, and anything
  that had moved rebuilt. That is why a writer which announced nothing looked
  exactly like one that worked — whoever read next fixed it.

  Reads serve rows now. Which closes the hole and opens a new question: a stale
  row and a current one are indistinguishable to a reader, so a writer that
  still says nothing is wrong *silently*.

  This is the answer to that question, and it is deliberately the expensive
  comparison the read used to do — the whole diff, on every read, reporting
  instead of repairing. Off by default; turned on where the writers are still
  being found.

      config :code_my_spec, graph_stale_read_log: true

  Every line it prints names a write that reached the database without reaching
  `GraphInputs.changed/2`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{GraphWatcher, RequirementGraph}

  setup do
    scope = full_scope_fixture()
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphWatcher.settle(scope)

    on_exit(fn -> Application.delete_env(:code_my_spec, :graph_stale_read_log) end)

    %{scope: scope}
  end

  # A write that lands in the database and announces nothing.
  #
  # `updated_at` is bumped deliberately: `Freshness.row_key/1` is
  # `{id, updated_at}`, and a real writer goes through a changeset, which bumps
  # it. `update_all` does not, so a probe without this changes a column the
  # fingerprint does not read and proves nothing — which is exactly what it did
  # on the first attempt.
  defp silently_change(story) do
    Repo.update_all(
      from(s in "stories", where: s.id == ^story.id),
      set: [
        description: "changed with nothing announcing it",
        updated_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_naive()
      ]
    )
  end

  defp read(scope), do: RequirementGraph.cached_graph_with_actionable(scope, settle: false)

  describe "with the log turned on" do
    setup do
      Application.put_env(:code_my_spec, :graph_stale_read_log, true)
      :ok
    end

    test "a read names the entity it served stale", %{scope: scope} do
      moved = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
      _left_alone = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
      :ok = GraphWatcher.settle(scope)

      silently_change(moved)

      log = capture_log(fn -> read(scope) end)

      assert log =~ "STALE READ"

      assert log =~ "story:#{moved.id}",
             """
             The stale read did not name the story whose inputs moved.

             A count cannot be acted on; an id can be traced to the write that
             moved it, and to the writer that did not say so. That is the whole
             point of the line.

             #{log}
             """
    end

    test "a read with nothing stale says nothing", %{scope: scope} do
      _story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
      :ok = GraphWatcher.settle(scope)

      log = capture_log(fn -> read(scope) end)

      refute log =~ "STALE READ",
             """
             A read reported staleness against a graph nothing had changed.

             This runs on every read once enabled. A line that appears when
             nothing is wrong is a line nobody reads when something is.

             #{log}
             """
    end
  end

  test "off by default, a stale read is silent", %{scope: scope} do
    story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{ready_for_dev: true})
    :ok = GraphWatcher.settle(scope)

    silently_change(story)

    log = capture_log(fn -> read(scope) end)

    refute log =~ "STALE READ",
           """
           The stale-read diagnostic ran without being turned on.

           It is the expensive half of a recompute — every entity's fingerprint
           rebuilt and diffed — on every read. Paying that by default would
           undo the change it exists to verify.

           #{log}
           """
  end
end
