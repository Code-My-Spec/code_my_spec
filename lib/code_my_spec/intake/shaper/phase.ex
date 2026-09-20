defmodule CodeMySpec.Intake.Shaper.Phase do
  @moduledoc """
  The shaper, run as a `CodeMySpec.Agents.Phase`.

  A drop-in for `CodeMySpec.Intake.Shaper.Llm` behind the same config seam:

      config :code_my_spec, CodeMySpec.Intake, shaper: CodeMySpec.Intake.Shaper.Phase

  Everything about shaping — the prompt, the tool, the two-question budget —
  lives in `CodeMySpec.Intake.Phases.Shape`. This is the adapter that keeps the
  funnel's existing contract while that moves.

  `shape/2` and `conclude/2` run the same code, which is the point. The old split
  existed because the caller had to decide whether asking was still allowed and
  pass `ask_allowed:` down; the phase derives the same thing from the turns it is
  holding, so the cap is a property of the state rather than of which function
  the caller picked.
  """

  @behaviour CodeMySpec.Intake.Shaper

  alias CodeMySpec.Agents.Phase
  alias CodeMySpec.Agents.Phase.Model
  alias CodeMySpec.Intake.Phases.Shape
  alias CodeMySpec.Intake.Plan

  require Logger

  @impl true
  def shape(%Plan{} = plan, turns), do: advance(plan, turns)

  @impl true
  def conclude(%Plan{} = plan, turns) do
    # Never `{:ask, _}`: `conclude/2` is only reached at the cap, and the phase
    # drops a question once the turns say it has no budget left.
    case advance(plan, turns) do
      {:ask, question} ->
        Logger.warning("[Intake.Shaper.Phase] question past the cap, dropped: #{question}")
        {:error, :asked_past_cap}

      other ->
        other
    end
  end

  defp advance(plan, turns) do
    state = Shape.new(plan, turns)

    case Phase.advance(Shape, state, model: model(), req_options: req_options()) do
      {:complete, state} -> {:ok, Shape.answers(state)}
      {:ask, question, _state} -> {:ask, question}
      {:error, reason} -> failed(reason)
    end
  end

  defp failed(reason) do
    Logger.warning("[Intake.Shaper.Phase] the model call failed: #{inspect(reason)}")
    {:error, reason}
  end

  # A test's cassette plug, most often. Config-driven rather than a new public
  # parameter: this module already reads `:model` from the same bag, and a second
  # way to reach it would only invite the two to drift.
  defp req_options, do: config()[:req_options] || []

  defp model, do: config()[:model] || Model.default_model()

  defp config, do: Application.get_env(:code_my_spec, CodeMySpec.Intake, [])
end
