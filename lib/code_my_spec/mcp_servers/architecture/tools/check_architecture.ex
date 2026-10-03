defmodule CodeMySpec.McpServers.Architecture.Tools.CheckArchitecture do
  @moduledoc """
  Compares the planned architecture against live code and reports where
  they disagree: an unplanned dependency, a planned dependency the code
  never uses, a planned component with no code, or code with no planned
  owner (story 1085).

  Always runnable, including when this project's `architecture` setting is
  `:off` — off only changes what the stop hook then does with a finding
  (nothing blocks), not whether a check can be requested.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, ArchitectureMapper.drift_response(drift_for(scope)), frame}

      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  # `:off` reports nothing (criterion 1735) — the mode gates this tool's own
  # report, not only the stop hook's blocking decision, so an engineer who
  # turned checking off is not shown findings a moment later by asking
  # directly.
  defp drift_for(scope) do
    case Configurations.get_or_create(scope).architecture do
      :off -> :off
      _mode -> Architecture.check_drift(scope)
    end
  end
end
