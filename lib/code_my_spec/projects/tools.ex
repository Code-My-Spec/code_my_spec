defmodule CodeMySpec.Projects.Tools do
  @moduledoc "Project definition tools available before a working copy exists."
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Projects, CodeMySpec.Devices, CodeMySpec.Tools, CodeMySpec.Paths]

  def all,
    do: [
      __MODULE__.GetProjectOnboarding,
      __MODULE__.UpdateProjectOnboarding,
      __MODULE__.SetupLocalProject
    ]

  def snapshot(project, scope) do
    %{
      phase: CodeMySpec.Projects.Onboarding.phase(project),
      project_id: project.id,
      name: project.name,
      local_directory: local_directory(project),
      onboarding: embedded(project.onboarding),
      sources: Enum.map(project.sources, &embedded/1),
      available_devices:
        Enum.map(CodeMySpec.Devices.list_harness_devices(scope), fn device ->
          %{
            id: device.id,
            name: CodeMySpec.Devices.Device.display_name(device),
            kind: device.kind
          }
        end)
    }
  end

  defp local_directory(project) do
    if Application.get_env(:code_my_spec, :env) == :desktop do
      (project.onboarding && project.onboarding.destination_path) || project.local_path ||
        CodeMySpec.Paths.project_home(project)
    end
  end

  defp embedded(nil), do: %{}

  defp embedded(value) do
    value
    |> Map.from_struct()
    |> Map.new(fn
      {key, %DateTime{} = timestamp} -> {key, DateTime.to_iso8601(timestamp)}
      {key, field} -> {key, field}
    end)
  end

  def text({:ok, data}), do: {:ok, Jason.encode!(data)}
  def text(error), do: error

  def error(%Ecto.Changeset{} = changeset) do
    {:error,
     "Invalid onboarding choices: " <>
       Jason.encode!(CodeMySpec.Tools.changeset_error_map(changeset))}
  end

  def error(:missing_active_project),
    do:
      {:error,
       "Open a project in /app before recording onboarding choices. No working copy is required."}

  def error(reason), do: CodeMySpec.Tools.error(reason)
end
