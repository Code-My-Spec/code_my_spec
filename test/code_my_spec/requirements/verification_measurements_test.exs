defmodule CodeMySpec.Requirements.VerificationMeasurementsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.Shadow

  test "failed drains retain failure and unknown counts in the published report" do
    id = Ecto.UUID.generate()

    assert_raise RuntimeError, "failed measurement", fn ->
      DrainCost.measure(%{kind: :event, project_id: id, observations: 1}, fn ->
        raise "failed measurement"
      end)
    end

    report = DrainCost.last(id, :event)
    assert report.raised
    assert report.handled == nil
    assert report.recomputed == nil
    assert report.measurement_scope == :projection
    assert %DateTime{} = report.measured_at
  end

  test "thrown drains retain failure and propagate the original value" do
    id = Ecto.UUID.generate()

    assert catch_throw(
             DrainCost.measure(%{kind: :event, project_id: id}, fn -> throw(:stopped) end)
           ) == :stopped

    assert DrainCost.last(id, :event).raised
  end

  test "exiting drains retain failure and propagate the original reason" do
    id = Ecto.UUID.generate()

    assert catch_exit(
             DrainCost.measure(%{kind: :event, project_id: id}, fn -> exit(:stopped) end)
           ) == :stopped

    assert DrainCost.last(id, :event).raised
  end

  test "successful drains explicitly record success" do
    id = Ecto.UUID.generate()

    assert :done =
             DrainCost.measure(%{kind: :event, project_id: id}, fn ->
               {:done, %{handled: 2, recomputed: 0}}
             end)

    report = DrainCost.last(id, :event)
    refute report.raised
    assert report.handled == 2
    assert report.recomputed == 0
  end
end
