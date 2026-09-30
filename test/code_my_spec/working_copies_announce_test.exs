defmodule CodeMySpec.WorkingCopiesAnnounceTest do
  @moduledoc """
  A working copy tells the graph when something the graph reads has moved, and
  stays quiet otherwise.

  Criterion 3339 already draws this line on the *fingerprint* — "a status
  changing is a change; a report time is not" — and the fingerprint honoured it.
  The announcement did not, so a preview health poll woke the watcher every time
  it confirmed an unchanged status, and the fingerprint's only contribution was
  to discover, after a preload, that nothing had moved.

  Measured on dev before this: ~6 announcements a minute, 11,958 in the retained
  logs against 144 from `Issues` — 78% of every graph input event on the
  machine, for a value that was not changing.

  The fields the graph actually reads are `main`, `preview_status` and
  `preview_url`: `Preloader.working_copy_gate_inputs/2` selects exactly those
  and `Promotion.running_copy_check/2` reads the same three.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Requirements.Invalidations
  alias CodeMySpec.Staffing
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/a/checkout")

    drain(scope)

    %{scope: scope, copy: copy}
  end

  # Marks are what an announcement leaves behind, and reading them is steadier
  # than racing a PubSub message.
  defp drain(scope) do
    marks = Invalidations.pending(scope.active_project_id)
    Invalidations.consume(marks)
    marks
  end

  defp announced?(scope), do: drain(scope) != []

  describe "a preview health poll" do
    test "announces when the status changes", %{scope: scope, copy: copy} do
      {:ok, _} = WorkingCopies.record_preview_status(copy, "serving")

      assert announced?(scope),
             "a preview status moving is a graph input — `story_promoted` reads it"
    end

    test "stays quiet when the status is unchanged", %{scope: scope, copy: copy} do
      {:ok, serving} = WorkingCopies.record_preview_status(copy, "serving")
      drain(scope)

      # The poll that found it still serving. `preview_checked_at` moves and
      # nothing the graph reads does.
      {:ok, _} = WorkingCopies.record_preview_status(serving, "serving")

      refute announced?(scope),
             "confirming an unchanged status is a check, not a change"
    end

    test "stays quiet across repeated confirmations", %{scope: scope, copy: copy} do
      {:ok, serving} = WorkingCopies.record_preview_status(copy, "serving")
      drain(scope)

      latest =
        Enum.reduce(1..5, serving, fn _, acc ->
          {:ok, next} = WorkingCopies.record_preview_status(acc, "serving")
          next
        end)

      refute announced?(scope), "five polls, nothing moved, nothing to say"
      assert latest.preview_status == "serving"
    end
  end

  describe "designation" do
    test "announces, because it moves which copy is the running one", %{scope: scope} do
      {:ok, other} =
        WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/a/second")

      drain(scope)

      {:ok, _} = Staffing.designate_main(scope, other.id)

      # This announced nothing before. `designate_main/2` broadcasts on the
      # context's own topic and never reached `GraphInputs`, and the clearing
      # half is an `update_all` that never passes through `save/2` — so moving
      # the designation left `story_promoted` answering from the old copy
      # until something unrelated moved the graph.
      assert announced?(scope),
             "designation changes `main` and therefore whose preview the graph reads"
    end
  end

  describe "record_app_status/2 (story 1108)" do
    test "persists status, url and commit together", %{copy: copy} do
      {:ok, updated} =
        WorkingCopies.record_app_status(copy, %{
          status: "serving",
          url: "http://127.0.0.1:51234",
          commit: "abc123"
        })

      assert updated.app_status == "serving"
      assert updated.app_url == "http://127.0.0.1:51234"
      assert updated.app_commit == "abc123"
      assert updated.app_checked_at
    end

    test "a health-probe-only report keeps the existing url and commit", %{copy: copy} do
      {:ok, started} =
        WorkingCopies.record_app_status(copy, %{
          status: "serving",
          url: "http://127.0.0.1:51234",
          commit: "abc123"
        })

      {:ok, polled} = WorkingCopies.record_app_status(started, %{status: "serving"})

      assert polled.app_url == "http://127.0.0.1:51234"
      assert polled.app_commit == "abc123"
    end

    test "going down clears the url regardless of what's passed", %{copy: copy} do
      {:ok, started} =
        WorkingCopies.record_app_status(copy, %{
          status: "serving",
          url: "http://127.0.0.1:51234",
          commit: "abc123"
        })

      {:ok, stopped} =
        WorkingCopies.record_app_status(started, %{status: "down", url: "http://127.0.0.1:51234"})

      assert stopped.app_status == "down"

      assert stopped.app_url == nil,
             "a stale address on a stopped copy is the bug this story fixes"

      assert stopped.app_commit == "abc123"
    end

    test "does not announce — this story hasn't wired the graph to read it yet", %{
      scope: scope,
      copy: copy
    } do
      {:ok, _} = WorkingCopies.record_app_status(copy, %{status: "serving", url: "http://x"})

      refute announced?(scope),
             "app_status/app_url are not in @graph_fields yet — phase 2 of story 1108 wires " <>
               "them into the requirement graph, not this increment"
    end
  end
end
