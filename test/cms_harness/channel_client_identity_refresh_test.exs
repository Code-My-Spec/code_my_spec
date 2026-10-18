defmodule CmsHarness.ChannelClientIdentityRefreshTest do
  @moduledoc """
  1a8e6318: `Project.Supervisor`'s child spec closes over the `project`
  struct `ProjectIdentity.resolve/1` returned once, at copy-serve time --
  before anything had joined, so its `working_copy_id` was still nil then. A
  later join writes the issued id to disk and into that one process's own
  socket assigns, never back into the supervisor's frozen argument. A
  `:rest_for_one` restart of `ChannelClient` used to re-`init/1` from that
  same stale struct and re-present `nil`, minting a fresh row on every such
  restart -- churn the device+root fallback happened to hide until it was
  removed (45c044d1).
  """
  use ExUnit.Case, async: true

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Project.ChannelClient

  @id "8a663385-d043-4538-bcb3-4b4a31a8c207"

  defp project(root, working_copy_id),
    do: %{id: "p1", root: root, working_copy_id: working_copy_id, preview_url: nil}

  test "init re-reads the id a prior join already persisted, rather than the stale nil it started with" do
    root = CodeMySpec.TempFile.owned_dir("test")
    :ok = HarnessConfig.write(root, %{working_copy_id: @id, project_id: "p1", root: root})

    {:ok, socket, {:continue, :connect}} = ChannelClient.init(project(root, nil))

    assert socket.assigns.project.working_copy_id == @id
  end

  test "init leaves the id alone when nothing has been issued yet" do
    root = CodeMySpec.TempFile.owned_dir("test")

    {:ok, socket, {:continue, :connect}} = ChannelClient.init(project(root, nil))

    refute socket.assigns.project.working_copy_id
  end

  test "init keeps the id already held when the passed struct already carries one" do
    root = CodeMySpec.TempFile.owned_dir("test")
    :ok = HarnessConfig.write(root, %{working_copy_id: @id, project_id: "p1", root: root})

    {:ok, socket, {:continue, :connect}} = ChannelClient.init(project(root, @id))

    assert socket.assigns.project.working_copy_id == @id
  end
end
