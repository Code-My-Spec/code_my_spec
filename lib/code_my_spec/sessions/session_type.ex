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
    AgentTasks.ContextSpec,
    AgentTasks.ControllerSpec,
    AgentTasks.DesignUi,
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
    AgentTasks.PersonaResearch,

    AgentTasks.ProjectSetup,
    AgentTasks.SpexBoundaryReady,
    AgentTasks.QaApp,
    AgentTasks.QaIntegrationPlan,
    AgentTasks.QaJourney,
    AgentTasks.QaSetup,
    AgentTasks.QaStory,
    AgentTasks.ResearchTopic,
    AgentTasks.StartImplementation,
    AgentTasks.StoryInterview,
    AgentTasks.TechnicalStrategy,
    AgentTasks.ThreeAmigos,
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
    # Short name ("TechnicalStrategy") first, then full atom string
    # ("Elixir.CodeMySpec.AgentTasks.TechnicalStrategy").
    case Map.get(mapper(), string) do
      nil -> cast_full_atom(string)
      module -> {:ok, module}
    end
  end

  def cast(_module), do: :error

  defp cast_full_atom(string) do
    atom = String.to_existing_atom(string)
    if atom in @valid_types, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  @spec load(binary()) :: {:ok, t()} | :error
  def load(data) when is_binary(data) do
    # Tolerant load: accept any pre-existing atom, even if the module
    # has since been renamed or removed from `@valid_types`. Strict
    # validation stays on `cast/1` so NEW writes are still rejected
    # for unknown types — this only matters when reading legacy task
    # rows whose `session_type` points at a deleted module (e.g. an
    # old `QaPreflight` or `ContextImplementation` task from before
    # those modules were consolidated/removed).
    #
    # The accompanying `Sessions` context prunes orphan tasks on the
    # read path (see `Sessions.maybe_prune_orphan_tasks/1`) so the
    # legacy entries disappear from disk the first time a session is
    # touched.
    {:ok, String.to_existing_atom(data)}
  rescue
    ArgumentError -> :error
  end

  @doc "Returns the list of module atoms accepted by `cast/1`."
  @spec valid_types() :: [t()]
  def valid_types, do: @valid_types

  @doc "Returns true if the given atom is in `@valid_types`."
  @spec valid_type?(atom()) :: boolean()
  def valid_type?(module) when is_atom(module), do: module in @valid_types
  def valid_type?(_), do: false

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
