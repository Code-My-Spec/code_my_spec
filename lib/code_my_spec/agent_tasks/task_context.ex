defmodule CodeMySpec.AgentTasks.TaskContext do
  @moduledoc "Resolves task identity and owned files from a subagent transcript."

  alias CodeMySpec.{Components, Utils}
  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.Transcripts.TaskIdentifier

  @type t :: %{module: module(), component: Components.Component.t(), files: [String.t()]}

  @spec resolve(map(), keyword()) :: {:ok, t()} | :none
  def resolve(scope, opts \\ []) do
    transcript_path = Keyword.get(opts, :transcript_path)
    if transcript_path, do: resolve_from_transcript(scope, transcript_path), else: :none
  end

  defp resolve_from_transcript(scope, transcript_path) do
    case TaskIdentifier.identify(transcript_path) do
      {:ok, %{type: type_name, component: module_name}} ->
        module = SessionType.mapper() |> Map.get(type_name)
        if module, do: build_context(scope, module, module_name), else: :none

      :none ->
        :none
    end
  end

  defp build_context(scope, module, component_module_name) do
    case Components.get_component_by_module_name(scope, component_module_name) do
      nil ->
        :none

      component ->
        files = Utils.component_files(component, scope.active_project) |> Map.values()
        {:ok, %{module: module, component: component, files: files}}
    end
  end
end
