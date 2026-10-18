defmodule CodeMySpec.Provisioning.Tools.ReadProjectFile do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Environments
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Resources
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "read_project_file"

  @impl true
  def description do
    """
    Read a file from a project's own checkout.

    Read-only counterpart to `generate_deploy_files`. `devops_status`'s audit can
    say a file is misconfigured (`force_ssl` without a health exclusion, say) but
    never shows the content — and `DeployArtifacts.generate/2` deliberately never
    overwrites a file that already exists, so a misconfigured (as opposed to
    missing) artifact has no automated fix. Seeing the real content is the step
    before deciding how to fix it by hand.
    """
  end

  @impl true
  def params do
    %{
      path: {:required, {:meta, :string, [description: "Path relative to the project root."]}}
    }
  end

  @impl true
  def call(%{path: path}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scoped = Resources.project_scope(scope, project)

      scoped
      |> project_environment(project)
      |> read_file(path)
      |> reply(path)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp project_environment(%{active_working_copy_id: copy_id} = scope, _project)
       when is_binary(copy_id),
       do: WorkingCopies.environment(scope)

  defp project_environment(_scope, project), do: LocalScope.environment(project)

  defp read_file(nil, _path), do: {:error, :no_working_environment}
  defp read_file(environment, path), do: Environments.read_file(environment, path)

  defp reply({:ok, content}, _path), do: ok(content)
  defp reply({:error, :enoent}, path), do: error("#{path}: not found")
  defp reply({:error, reason}, _path), do: error(reason)

  defp ok(content), do: {:ok, content}

  defp error(reason),
    do: {:error, "Could not read the file: #{inspect(reason)}"}
end
