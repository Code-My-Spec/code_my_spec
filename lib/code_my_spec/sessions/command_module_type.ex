defmodule CodeMySpec.Sessions.CommandModuleType do
  @moduledoc false

  use Ecto.Type
  require Logger

  @valid_modules [
    CodeMySpec.ContextComponentsDesignSessions.Steps.Initialize,
    CodeMySpec.ContextComponentsDesignSessions.Steps.SpawnComponentSpecSessions,
    CodeMySpec.ContextComponentsDesignSessions.Steps.SpawnReviewSession,
    CodeMySpec.ContextComponentsDesignSessions.Steps.Finalize,
    CodeMySpec.ComponentSpecSessions.Steps.Initialize,
    CodeMySpec.ComponentSpecSessions.Steps.GenerateComponentSpec,
    CodeMySpec.ComponentSpecSessions.Steps.ValidateSpec,
    CodeMySpec.ComponentSpecSessions.Steps.ReviseSpec,
    CodeMySpec.ComponentSpecSessions.Steps.Finalize,
    CodeMySpec.ComponentCodingSessions.Steps.Initialize,
    CodeMySpec.ComponentCodingSessions.Steps.GenerateImplementation,
    CodeMySpec.ComponentCodingSessions.Steps.RunTests,
    CodeMySpec.ComponentCodingSessions.Steps.FixTestFailures,
    CodeMySpec.ComponentCodingSessions.Steps.Finalize
  ]

  def type, do: :string

  def cast(module) when is_atom(module) do
    {:ok, module}
  end

  def cast(string) when is_binary(string) do
    Map.get(string_mapper(), string)
    |> cast
  end

  def cast(_), do: :error

  def load(data) when is_binary(data) do
    {:ok, Map.get(string_mapper(), data)}
  end

  def dump(module) when is_atom(module) do
    {:ok, Atom.to_string(module)}
  end

  def dump(_), do: :error

  def string_mapper do
    Enum.reduce(@valid_modules, %{}, fn type, acc ->
      Map.put(acc, type |> Atom.to_string(), type)
    end)
  end
end
