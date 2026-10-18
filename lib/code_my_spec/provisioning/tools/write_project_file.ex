defmodule CodeMySpec.Provisioning.Tools.WriteProjectFile do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Environments
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Resources
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "write_project_file"

  @impl true
  def description do
    """
    Overwrite a file in a project's own checkout.

    `DeployArtifacts.generate/2` deliberately never touches a file that already
    exists — a project that customised its Dockerfile did so for a reason. That
    is right for *scaffolding* a missing artifact and wrong for *fixing* one
    `devops_status`'s audit has already named as misconfigured (`force_ssl`
    without a health exclusion, say): there, the file exists, is wrong, and
    regenerating from the template would silently discard whatever else the
    project put there. This is the deliberate, explicit override for that case —
    read the real content with `read_project_file` first, change only what needs
    changing, and write the whole file back.
    """
  end

  @impl true
  def params do
    %{
      path: {:required, {:meta, :string, [description: "Path relative to the project root."]}},
      content:
        {:required,
         {:meta, :string, [description: "Full file content — this replaces whatever is there."]}}
    }
  end

  @impl true
  def call(%{path: path, content: content}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scoped = Resources.project_scope(scope, project)

      scoped
      |> project_environment(project)
      |> write_file(path, content)
      |> reply(path)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp project_environment(%{active_working_copy_id: copy_id} = scope, _project)
       when is_binary(copy_id),
       do: WorkingCopies.environment(scope)

  defp project_environment(_scope, project), do: LocalScope.environment(project)

  defp write_file(nil, _path, _content), do: {:error, :no_working_environment}

  defp write_file(environment, path, content),
    do: Environments.write_file(environment, path, content)

  defp reply(:ok, path), do: ok("Wrote #{path}.")
  defp reply({:ok, _}, path), do: ok("Wrote #{path}.")
  defp reply({:error, reason}, _path), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not write the file: #{inspect(reason)}"}
end
