defmodule CodeMySpec.Workspaces.TrackingTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Events
  alias CodeMySpec.Workspaces.{Tracking, Workspace}

  defp workspace(attrs) do
    struct(
      %Workspace{
        project_id: Ecto.UUID.generate(),
        status: :booting,
        booted_at: DateTime.add(DateTime.utc_now(:second), -45, :second)
      },
      attrs
    )
  end

  describe "abandoned/1" do
    test "records the phase the visitor left on and how long they waited" do
      workspace = workspace(step: :fetching_deps)

      assert :ok = Tracking.abandoned(workspace)
      assert Events.exists?("workspace_abandoned", project_id: workspace.project_id)

      event = only_event("workspace_abandoned")
      assert event.data["step"] == "fetching_deps"
      assert event.data["waited_seconds"] >= 45
    end

    test "a workspace that already came up is not an abandonment" do
      assert :ok = Tracking.abandoned(workspace(status: :running, step: :starting_app))

      refute Events.exists?("workspace_abandoned")
    end

    test "a workspace that already failed is not an abandonment" do
      assert :ok = Tracking.abandoned(workspace(status: :failed, step: :fetching_deps))

      refute Events.exists?("workspace_abandoned")
    end
  end

  describe "outcomes" do
    test "coming up records the wait it cost" do
      assert :ok = Tracking.running(workspace(status: :running, step: :starting_app))

      event = only_event("workspace_running")
      assert event.event_type == "workspace_running"
      assert event.data["waited_seconds"] >= 45
    end

    test "failing carries what went wrong and where" do
      workspace = workspace(status: :failed, step: :migrating, error: "took too long to start")

      assert :ok = Tracking.failed(workspace)

      event = only_event("workspace_failed")
      assert event.event_type == "workspace_failed"
      assert event.data["step"] == "migrating"
      assert event.data["error"] == "took too long to start"
    end

    test "a retry's wait is its own, not the sum of every attempt" do
      # booting_changeset stamps booted_at fresh, so a retry that has only
      # just started reports a short wait even on an old workspace row.
      Tracking.abandoned(workspace(booted_at: DateTime.utc_now(:second)))

      event = only_event("workspace_abandoned")
      assert event.data["waited_seconds"] < 5
    end
  end

  # By type, not "the only row in the table" — that assumption held only
  # because the sandbox starts empty, and it broke the moment anything wrote
  # an event outside it.
  defp only_event(event_type) do
    import Ecto.Query
    Repo.one!(from e in Events.Event, where: e.event_type == ^event_type)
  end
end
