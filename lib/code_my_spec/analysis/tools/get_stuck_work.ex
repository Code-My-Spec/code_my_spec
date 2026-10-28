defmodule CodeMySpec.Analysis.Tools.GetStuckWork do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis.StuckWork

  @impl true
  def name, do: "get_stuck_work"

  @impl true
  def description do
    "Analysis runs and promotion entries started and finished in the last 24 hours, their oldest open age, and items currently stuck by duration or silence. Reports new stuck items to Main."
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      scope
      |> StuckWork.check()
      |> Jason.encode!()
      |> then(&{:ok, &1})
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, StuckWork.check(scope) |> Jason.encode!() |> Jason.decode!()}
    end
  end
end
