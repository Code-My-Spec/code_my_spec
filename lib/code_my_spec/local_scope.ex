defmodule CodeMySpec.LocalScope do
  @moduledoc """
  Builds scopes for local projects by resolving their registered environment
  or falling back to an explicit root or the project's persisted local path.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Users.Scope, CodeMySpec.Environments],
    exports: :all

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Users.Scope

  @doc """
  Builds a complete local scope from a project record, preferring a live
  checkout over `local_path`.

  A root-specific registry entry wins over the project's entry because a
  project may have several working copies. If neither registration exists,
  resolution falls back to `root || project.local_path`.
  """
  @spec for_local_project(struct() | nil, String.t() | nil) ::
          {:ok, Scope.t()} | {:error, :no_local_path}
  def for_local_project(project, root \\ nil)

  def for_local_project(nil, _root), do: {:error, :no_local_path}

  def for_local_project(%_{} = project, root) do
    case resolve_environment(project, root) do
      %Environment{cwd: nil} ->
        {:error, :no_local_path}

      %Environment{} = env ->
        {:ok,
         %Scope{
           active_account: nil,
           active_account_id: project.account_id,
           active_project: project,
           active_project_id: project.id,
           cwd: env.cwd,
           environment: env
         }}
    end
  end

  defp resolve_environment(project, root) do
    case registered_for(root) || Environments.lookup_registered(project.id) do
      nil -> Environment.new(:local, root || project.local_path)
      %Environment{} = env -> env
    end
  end

  defp registered_for(nil), do: nil
  defp registered_for(root), do: Environments.lookup_registered({:root, root})
end
