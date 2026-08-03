defmodule CodeMySpec.Intake.Funnel do
  @moduledoc """
  Records how far visitors get before the gate.

  The current funnel leaks worst between the call to action and the register
  view, and the bet behind guided intake is that showing something specific to
  the visitor first fixes it. These events are how that bet gets settled.

  Everything after the gate is `CodeMySpec.Workspaces.Tracking`'s — a boot
  transition happens in a background task and has to be recorded where it
  happens rather than by whoever is listening.
  """

  alias CodeMySpec.{Analytics, Events}

  @doc "A step of the pre-gate flow reached, identified by the anonymous plan."
  @spec plan_reached(atom(), map()) :: :ok
  def plan_reached(step, data) when is_atom(step) and is_map(data) do
    name = :"intake_#{step}"

    Analytics.dispatch(name, data, :server)
    Events.record(name, data)
    :ok
  end
end
