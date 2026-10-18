defmodule CodeMySpec.Architecture.Tools.CheckArchitecture do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Architecture
  alias CodeMySpec.Configurations
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper

  @impl true
  def name, do: "check_architecture"

  @impl true
  def description do
    """
    Compares the planned architecture against live code and reports where
    they disagree: an unplanned dependency, a planned dependency the code
    never uses, a planned component with no code, or code with no planned
    owner (story 1085).

    Always runnable, including when this project's `architecture` setting is
    `:off` — off only changes what the stop hook then does with a finding
    (nothing blocks), not whether a check can be requested.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        ArchitectureMapper.drift_response(drift_for(scope))

      {:error, reason} ->
        ArchitectureMapper.error(reason)
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
