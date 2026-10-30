defmodule CodeMySpec.PromotionQueue.WaitsStatusTest do
  @moduledoc """
  Why the queue cannot gate is kept for the machinery report, from the first
  refusal, until it gates again (criterion 2482).
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.PromotionQueue.Waits

  setup do
    %{project_id: Ecto.UUID.generate()}
  end

  test "an empty queue that can gate reports nothing blocking", %{project_id: id} do
    assert Waits.status(id) == %{queued: 0, gating: nil, blocked: nil}
  end

  test "a refusal is reported with its reason, timed from the first one", %{project_id: id} do
    :ok = Waits.record_blocked(id, "the project has no gate copy")
    %{blocked: %{since: first}} = Waits.status(id)

    :ok = Waits.record_blocked(id, "could not read the gate copy's HEAD")

    assert %{blocked: %{reason: "could not read the gate copy's HEAD", since: ^first}} =
             Waits.status(id)
  end

  test "gating again clears it", %{project_id: id} do
    :ok = Waits.record_blocked(id, "the project has no gate copy")
    :ok = Waits.clear_blocked(id)
    assert Waits.status(id).blocked == nil
  end
end
