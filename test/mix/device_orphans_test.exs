defmodule Mix.Tasks.Cms.DeviceOrphansTest do
  @moduledoc """
  What the sweep for issue 2dd9a959 is allowed to call orphaned.

  One fact decides it, and nothing else: whether any `working_copies` row
  still points at the device. `destroy/2`'s own moduledoc says why that has
  to be exact — a device *with* working copies attached cascades them away
  with it (migration `20260830120000`), so a wrong "yes" here is not a stale
  row removed, it is somebody's real checkouts gone.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias Mix.Tasks.Cms.DeviceOrphans

  describe "a device with no working copies" do
    test "is an orphan" do
      assert DeviceOrphans.orphan?(%Device{working_copies: []})
    end
  end

  describe "a device with at least one working copy" do
    test "is not an orphan, even sharing a hostname with a real orphan" do
      refute DeviceOrphans.orphan?(%Device{
               hostname: "Johns-Mac-mini",
               working_copies: [%WorkingCopy{}]
             })
    end

    test "still is not an orphan with several attached" do
      refute DeviceOrphans.orphan?(%Device{working_copies: [%WorkingCopy{}, %WorkingCopy{}]})
    end
  end
end
