defmodule CodeMySpec.Analysis.Tools do
  @moduledoc "The analysis tools an agent calls."

  def all,
    do: [__MODULE__.GetAnalysisOutput, __MODULE__.GetAnalysisLive, __MODULE__.AwaitAnalysis]
end
