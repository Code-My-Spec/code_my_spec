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
             "a preview status moving is a graph input — `code_on_running_copy` reads it"
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

      {:ok, _} = WorkingCopies.designate_main(scope, other.id)

      # This announced nothing before. `designate_main/2` broadcasts on the
      # context's own topic and never reached `GraphInputs`, and the clearing
      # half is an `update_all` that never passes through `save/2` — so moving
      # the designation left `code_on_running_copy` answering from the old copy
      # until something unrelated moved the graph.
      assert announced?(scope),
             "designation changes `main` and therefore whose preview the graph reads"
    end
  end
end
