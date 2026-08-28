defmodule CodeMySpec.McpServers.Devops.Tools.WriteProjectFile do
  @moduledoc """
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

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Resources

  schema do
    field :path, :string, required: true, doc: "Path relative to the project root."
    field :content, :string, required: true, doc: "Full file content — this replaces whatever is there."
  end

  @impl true
  def execute(%{path: path, content: content} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> Map.fetch!(:environment)
      |> Environments.write_file(path, content)
      |> reply(path, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp reply(:ok, path, frame), do: {:reply, ok("Wrote #{path}."), frame}
  defp reply({:ok, _}, path, frame), do: {:reply, ok("Wrote #{path}."), frame}
  defp reply({:error, reason}, _path, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not write the file: #{inspect(reason)}")
end
