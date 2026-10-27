defmodule CodeMySpec.Analysis.History.Finding do
  @moduledoc "A normalized problem retained with the analyzer run that found it."

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Problems.Problem

  @type t :: %__MODULE__{}

  schema "analysis_run_findings" do
    belongs_to :run, Run
    field :severity, Ecto.Enum, values: [:error, :warning, :info]
    field :source_type, Ecto.Enum, values: [:static_analysis, :test, :runtime]
    field :source, :string
    field :file_path, :string
    field :line, :integer
    field :message, :string
    field :category, :string
    field :rule, :string
    field :metadata, :map
    field :test_name, :string
    field :criterion, :integer
    field :component_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec from_problem(Problem.t(), integer()) :: Ecto.Changeset.t()
  def from_problem(%Problem{} = problem, run_id) when is_integer(run_id) do
    metadata = problem.metadata || %{}

    %__MODULE__{}
    |> change(%{
      run_id: run_id,
      severity: problem.severity,
      source_type: problem.source_type,
      source: problem.source,
      file_path: problem.file_path,
      line: problem.line,
      message: problem.message,
      category: problem.category,
      rule: problem.rule,
      metadata: metadata,
      test_name: Map.get(metadata, "test"),
      criterion: criterion(problem.file_path),
      component_id: problem.component_id
    })
    |> validate_required([:run_id, :severity, :source, :message, :category])
  end

  defp criterion("test/spex/" <> path) do
    case Regex.run(~r/(?:^|\/)criterion_(\d+)_/, path) do
      [_, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp criterion(_path), do: nil
end
