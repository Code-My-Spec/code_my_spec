defmodule CodeMySpec.Sessions.SessionType do
  @moduledoc false

  use Ecto.Type

  alias CodeMySpec.AgentTasks

  @valid_types [
    AgentTasks.ArchitectureDesign,
    AgentTasks.ComponentCode,
    AgentTasks.ComponentSpec,
    AgentTasks.ComponentTest,
    AgentTasks.CodeGeneration,
    AgentTasks.ContextComponentSpecs,
    AgentTasks.ContextDesignReview,
    AgentTasks.ContextImplementation,
    AgentTasks.ContextSpec,
    AgentTasks.DesignUi,
    AgentTasks.DevelopComponent,
    AgentTasks.DevelopContext,
    AgentTasks.DevelopController,
    AgentTasks.DevelopLiveContext,
    AgentTasks.DevelopLiveView,
    AgentTasks.FixAllBddSpecs,
    AgentTasks.FixBddSpecs,
    AgentTasks.FixIssues,
    AgentTasks.LinkStoryComponent,
    AgentTasks.LiveContextSpec,
    AgentTasks.LiveViewSpec,

    AgentTasks.ProjectSetup,
    AgentTasks.QaApp,
    AgentTasks.QaIntegrationPlan,
    AgentTasks.QaJourney,
    AgentTasks.QaPreflight,
    AgentTasks.QaSetup,
    AgentTasks.QaStory,
    AgentTasks.RefactorModule,
    AgentTasks.ResearchTopic,
    AgentTasks.StartImplementation,
    AgentTasks.TechnicalStrategy,
    AgentTasks.TriageIssues,
    AgentTasks.WriteBddSpecs
  ]

  @type t :: atom()

  @spec type() :: :string
  def type, do: :string

  @spec cast(binary() | atom()) :: {:ok, t()} | :error

  def cast(module) when is_atom(module) and module in @valid_types do
    {:ok, module}
  end

  def cast(string) when is_binary(string) do
    # Try short name first ("TechnicalStrategy"), then full atom string ("Elixir.CodeMySpec.AgentTasks.TechnicalStrategy")
    case Map.get(mapper(), string) do
      nil -> cast_full_atom(string)
      module -> {:ok, module}
    end
  end

  def cast(_module), do: :error

  defp cast_full_atom(string) do
    try do
      atom = String.to_existing_atom(string)
      if atom in @valid_types, do: {:ok, atom}, else: :error
    rescue
      ArgumentError -> :error
    end
  end

  @spec load(binary()) :: {:ok, t()} | :error
  def load(data) when is_binary(data) do
    try do
      atom = String.to_existing_atom(data)

      if atom in @valid_types do
        {:ok, atom}
      else
        :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  @spec dump(atom()) :: {:ok, binary()} | :error
  def dump(module) when is_atom(module), do: {:ok, Atom.to_string(module)}
  def dump(_), do: :error

  def mapper do
    Enum.map(@valid_types, fn type ->
      {type |> Atom.to_string() |> String.split(".") |> List.last(), type}
    end)
    |> Enum.into(%{})
  end
end
