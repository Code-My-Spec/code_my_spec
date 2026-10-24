defmodule CodeMySpec.LocalScope do
  @moduledoc """
  Builds scopes for local projects by resolving their registered environment
  or falling back to an explicit root or the project's persisted local path.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Users.Scope, CodeMySpec.ExecutionContexts]

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Users.Scope

  @doc """
  Resolves an environment from a project and optional explicit root.

  A root-specific registry entry wins over the project's entry because a
  project may have several working copies. If neither registration exists,
  resolution falls back to `root || project.local_path`. Missing paths return
  `nil`; this operation never guesses a process working directory.
  """
  @spec execution_context(struct() | nil, String.t() | nil) :: ExecutionContext.t() | nil
  def execution_context(project, root \\ nil)

  def execution_context(nil, _root), do: nil

  def execution_context(%_{} = project, root) do
    env =
      registered_for(root) || ExecutionContexts.lookup_registered(project.id) ||
        ExecutionContext.new(:local, root || project.local_path)

    case env do
      %ExecutionContext{cwd: nil} ->
        nil

      %ExecutionContext{} = env ->
        env
    end
  end

  @doc """
  Builds a complete local scope from a project record, preferring a live
  checkout over `local_path`.

  Root-specific registration takes precedence over project registration.
  Missing paths return `{:error, :no_local_path}`.
  """
  @spec for_local_project(struct() | nil, String.t() | nil) ::
          {:ok, Scope.t()} | {:error, :no_local_path}
  def for_local_project(project, root \\ nil)

  def for_local_project(nil, _root), do: {:error, :no_local_path}

  def for_local_project(%_{} = project, root) do
    case execution_context(project, root) do
      nil ->
        {:error, :no_local_path}

      %ExecutionContext{} = env ->
        {:ok,
         %Scope{
           active_account: nil,
           active_account_id: project.account_id,
           active_project: project,
           active_project_id: project.id,
           cwd: env.cwd
         }}
    end
  end

  defp registered_for(nil), do: nil
  defp registered_for(root), do: ExecutionContexts.lookup_registered({:root, root})
end
