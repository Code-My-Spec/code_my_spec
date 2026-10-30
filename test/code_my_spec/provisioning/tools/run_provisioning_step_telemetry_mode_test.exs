defmodule CodeMySpec.Provisioning.Tools.RunProvisioningStepTelemetryModeTest do
  @moduledoc """
  `ClickHouse.run/3` reads `opts[:telemetry_mode]`, but the tool had no
  parameter for it, so every telemetry step ran the full stack: an uncapped
  ClickHouse beside other apps on a shared 4 GB box.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Tools.RunProvisioningStep

  test "a named mode reaches the step as its atom" do
    for mode <- ~w(full capped collector_only) do
      opts = RunProvisioningStep.run_opts(%{step: "telemetry", telemetry_mode: mode})
      assert opts[:telemetry_mode] == String.to_existing_atom(mode)
    end
  end

  test "an unknown mode reaches the step as given, for it to refuse by name" do
    opts = RunProvisioningStep.run_opts(%{step: "telemetry", telemetry_mode: "light"})
    assert opts[:telemetry_mode] == "light"
  end

  test "no mode leaves the step's default" do
    refute Keyword.has_key?(RunProvisioningStep.run_opts(%{step: "telemetry"}), :telemetry_mode)
  end
end
