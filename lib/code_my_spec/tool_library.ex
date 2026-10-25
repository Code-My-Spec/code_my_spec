defmodule CodeMySpec.ToolLibrary do
  @moduledoc """
  Every tool a domain offers agents, as one list every surface reads.

  Each domain owns its tools (`CodeMySpec.Personas.Tools`, ...); this module
  only lists them. A surface never reaches into a domain for a tool, so it
  depends on this list rather than on every domain behind it.

  `registrations/0` is the shape code mode and the agent tool index read: a
  name, a description, the JSON Schema of its arguments, the validator, and the
  tool module that runs it.

  See knowledge/tools, "Tool library".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.WorkingCopies.Tools,
      CodeMySpec.AppInstances.Tools,
      CodeMySpec.Devices.Tools,
      CodeMySpec.Environments.Tools,
      CodeMySpec.Projects.Tools,
      CodeMySpec.Stories.Tools,
      CodeMySpec.Provisioning.Tools,
      CodeMySpec.Components.Tools,
      CodeMySpec.Issues.Tools,
      CodeMySpec.Architecture.Tools,
      CodeMySpec.Requirements.Tools,
      CodeMySpec.Bootstrap.Tools,
      CodeMySpec.Agents.Tools,
      CodeMySpec.AgentAttachments.Tools,
      CodeMySpec.Qa.Tools,
      CodeMySpec.BddRules.Tools,
      CodeMySpec.AgentPerformance,
      CodeMySpec.Analysis,
      CodeMySpec.Embeddings,
      CodeMySpec.Knowledge,
      CodeMySpec.Observability,
      CodeMySpec.Personas,
      CodeMySpec.Problems.Tools,
      CodeMySpec.Research,
      CodeMySpec.Tools
    ]

  alias CodeMySpec.Tools

  @doc "Every tool module."
  @spec tools() :: [module()]
  def tools,
    do:
      CodeMySpec.Personas.Tools.all() ++
        CodeMySpec.Projects.Tools.all() ++
        CodeMySpec.Agents.Tools.all() ++
        CodeMySpec.AgentAttachments.Tools.all() ++
        CodeMySpec.Knowledge.Tools.all() ++
        CodeMySpec.Embeddings.Tools.all() ++
        CodeMySpec.Problems.Tools.all() ++
        CodeMySpec.Observability.Tools.all() ++
        CodeMySpec.Research.Tools.all() ++
        CodeMySpec.Analysis.Tools.all() ++
        CodeMySpec.AgentPerformance.Tools.all() ++
        CodeMySpec.WorkingCopies.Tools.all() ++
        CodeMySpec.AppInstances.Tools.all() ++
        CodeMySpec.Devices.Tools.all() ++
        CodeMySpec.Environments.Tools.all() ++
        CodeMySpec.Stories.Tools.all() ++
        CodeMySpec.Provisioning.Tools.all() ++
        CodeMySpec.Components.Tools.all() ++
        CodeMySpec.Issues.Tools.all() ++
        CodeMySpec.Architecture.Tools.all() ++
        CodeMySpec.Requirements.Tools.all() ++
        CodeMySpec.Bootstrap.Tools.all() ++
        CodeMySpec.Qa.Tools.all() ++
        CodeMySpec.BddRules.Tools.all()

  @doc """
  The names of tools that were removed and stay only to answer a stale caller
  (`CodeMySpec.Tools.Tool.tombstone?/0`). Callable, never advertised.
  """
  @spec tombstoned() :: [String.t()]
  def tombstoned do
    for tool <- tools(),
        Code.ensure_loaded?(tool) and function_exported?(tool, :tombstone?, 0) and
          tool.tombstone?(),
        do: tool.name()
  end

  @doc "Every tool, described for a surface."
  @spec registrations() :: [map()]
  def registrations, do: Enum.map(tools(), &registration/1)

  @doc "The tool with this name, if there is one."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case Enum.find(tools(), &(&1.name() == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @doc "Runs the tool named `name`, as any surface would."
  @spec run(String.t(), map(), Tools.context()) :: CodeMySpec.Tools.Tool.result()
  def run(name, args, context) do
    case fetch(name) do
      {:ok, tool} -> Tools.run(tool, args, context)
      :error -> {:error, "no tool named #{name}"}
    end
  end

  @doc """
  Runs the tool named `name` for its data: `script_result/2` when the tool has
  one, as a script would get it, else the text `call/2` answers.
  """
  @spec data(String.t(), map(), Tools.context()) :: {:ok, term()} | {:error, term()}
  def data(name, args, context) do
    with {:ok, tool} <- fetch_or_refuse(name),
         {:ok, params} <- Tools.validate(tool, args) do
      if function_exported?(Code.ensure_loaded!(tool), :script_result, 2),
        do: tool.script_result(params, context),
        else: tool.call(params, context)
    end
  end

  defp fetch_or_refuse(name) do
    case fetch(name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "no tool named #{name}"}
    end
  end

  @doc "One tool, described for a surface."
  @spec registration(module()) :: map()
  def registration(tool) do
    %{
      name: tool.name(),
      description: tool.description(),
      input_schema: Tools.input_schema(tool),
      validate_input: &Tools.validate(tool, &1),
      tool: tool
    }
  end
end
