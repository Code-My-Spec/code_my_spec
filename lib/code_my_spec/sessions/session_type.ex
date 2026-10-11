defmodule CodeMySpec.Sessions.SessionType do
  @moduledoc false

  use Ecto.Type

  alias CodeMySpec.AgentTasks

  @valid_types [
    AgentTasks.ArchitectureDesign,
    AgentTasks.ComponentCode,
    AgentTasks.ComponentTest,
    AgentTasks.CodeGeneration,
    AgentTasks.ContextComponentSpecs,
    AgentTasks.DesignUi,
    AgentTasks.Deploy,
    AgentTasks.DevelopContext,
    AgentTasks.DevelopController,
    AgentTasks.DevelopLiveContext,
    AgentTasks.DevelopLiveView,
    AgentTasks.DevopsSetup,
    AgentTasks.FixAllBddSpecs,
    AgentTasks.FixBddSpecs,
    AgentTasks.ReadyForQa,
    AgentTasks.FixIssues,
    AgentTasks.SubmitStoryIssue,
    AgentTasks.IssueFix,
    AgentTasks.IssuePromote,
    AgentTasks.IssueQa,
    AgentTasks.LinkStoryComponent,
    AgentTasks.PersonaResearch,
    AgentTasks.PromoteWork,
    AgentTasks.ProjectSetup,
    AgentTasks.Release,
    AgentTasks.SpexBoundaryReady,
    AgentTasks.QaApp,
    AgentTasks.QaIntegrationPlan,
    AgentTasks.QaJourney,
    AgentTasks.QaSetup,
    AgentTasks.QaStory,
    AgentTasks.ResearchTopic,
    AgentTasks.ResolveQuestions,
    AgentTasks.StartImplementation,
    AgentTasks.StoryInterview,
    AgentTasks.TechnicalStrategy,
    AgentTasks.ThreeAmigos,
    AgentTasks.TriageIssues,
    AgentTasks.WriteBddSpecs
  ]

  @type t :: atom()

  @impl true
  @spec type() :: :string
  def type, do: :string

  # Tasks are JSON embeds. Use the persisted representation so historical
  # task types reach load/1 instead of the strict validation for new input.
  @impl true
  def embed_as(_format), do: :dump

  @impl true
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

  @impl true
  @spec load(binary()) :: {:ok, t()} | :error
  def load(data) when is_binary(data) do
    # Tolerant load: convert the DB string to an atom whether or not
    # the matching module still exists in the release. Strict
    # validation stays on `cast/1` so NEW writes are still rejected
    # for unknown types — this only matters when reading legacy task
    # rows whose `session_type` points at a deleted module (e.g. an
    # old `QaPreflight` or `ContextImplementation` task from before
    # those modules were consolidated/removed).
    #
    # `to_atom/1` (vs `to_existing_atom/1`) is needed because deleted
    # modules don't pre-register their atom in the released BEAM, so
    # `to_existing_atom/1` would raise ArgumentError → Ecto sees
    # `:error` → crashes the row load. Safe here: the set of distinct
    # `session_type` strings ever written to disk is bounded (one per
    # historical agent task module).
    #
    # The accompanying `Sessions` context prunes orphan tasks on the
    # read path (see `Sessions.maybe_prune_orphan_tasks/1`) so the
    # legacy entries disappear from disk the first time a session is
    # touched.
    {:ok, String.to_atom(data)}
  end

  @doc "Returns the list of module atoms accepted by `cast/1`."
  @spec valid_types() :: [t()]
  def valid_types, do: @valid_types

  @doc "Returns true if the given atom is in `@valid_types`."
  @spec valid_type?(atom()) :: boolean()
  def valid_type?(module) when is_atom(module), do: module in @valid_types
  def valid_type?(_), do: false

  @impl true
  @spec dump(atom()) :: {:ok, binary()} | :error
  def dump(module) when is_atom(module), do: {:ok, Atom.to_string(module)}
  def dump(_), do: :error

  def mapper do
    Map.new(@valid_types, fn type ->
      {type |> Atom.to_string() |> String.split(".") |> List.last(), type}
    end)
  end
end
