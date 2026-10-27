defmodule CodeMySpec.Analysis.Tools.GetAnalysisHistory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis.History
  alias CodeMySpec.Tools

  @impl true
  def name, do: "get_analysis_history"

  @impl true
  def description, do: "Read completed analyzer runs with their retained failures and problems."

  @impl true
  def params do
    %{source: {:meta, :string, [description: "Optional analyzer source filter."]}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      runs = History.list(scope, source: params[:source])
      {:ok, Jason.encode!(%{runs: runs})}
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      {:ok, %{runs: History.list(scope, source: params[:source])}}
    end
  end
end
