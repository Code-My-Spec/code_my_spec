defmodule CodeMySpec.Sessions.SessionType do
  @moduledoc false

  use Ecto.Type

  alias CodeMySpec.AgentTasks

  @valid_types [
    AgentTasks.ComponentSpec,
    AgentTasks.ComponentCode,
    AgentTasks.ComponentTest,
    AgentTasks.ContextSpec,
    AgentTasks.ContextComponentSpecs,
    AgentTasks.ContextImplementation,
    AgentTasks.ContextDesignReview,
    AgentTasks.ArchitectureDesign,
    AgentTasks.ArchitectureReview,
    AgentTasks.ProjectSetup,
    AgentTasks.WriteBddSpecs,
    AgentTasks.ManageImplementation,
    AgentTasks.DevelopContext,
    AgentTasks.DevelopLiveView,
    AgentTasks.LiveViewSpec,
    AgentTasks.DesignUi,
    AgentTasks.TechnicalStrategy,
    AgentTasks.ResearchTopic,
    AgentTasks.DevelopLiveContext,
    AgentTasks.LiveContextSpec,
    AgentTasks.QaApp,
    AgentTasks.QaStory
  ]

  @type t :: atom()

  @spec type() :: :string
  def type, do: :string

  @spec cast(binary() | atom()) :: {:ok, t()} | :error

  def cast(module) when is_atom(module) and module in @valid_types do
    {:ok, module}
  end

  def cast(string) when is_binary(string) do
    Map.get(mapper(), string)
    |> cast
  end

  def cast(_module), do: :error

  @spec load(binary()) :: {:ok, t()} | :error
  def load(data) when is_binary(data), do: {:ok, String.to_atom(data)}

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
