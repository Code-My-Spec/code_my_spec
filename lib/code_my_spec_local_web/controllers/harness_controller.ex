defmodule CodeMySpecLocalWeb.HarnessController do
  @moduledoc """
  Onboarding a working copy: the one call that hands out an identity.

  Everything else about a harness is keyed on the id, so something has to issue
  the first one, and it cannot itself be keyed on the id. This is that
  something, and it is deliberately the only place a working copy is described
  by its path.

  Takes the project and root explicitly rather than inferring either from the
  request. Inference is what is being retired: a caller that has to say which
  project and which directory it means cannot silently mean a different one
  than the operator intended.

  Idempotent on a presented id. Re-running it in a checkout that already has an
  identity recognises that identity and updates the root, so onboarding twice
  is not two harnesses — otherwise a re-run would strand every row written
  under the first id.
  """

  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  def register(conn, params) do
    with {:ok, project_id} <- require_param(params, "project_id"),
         {:ok, root} <- require_param(params, "root"),
         {:ok, project} <- fetch_project(project_id),
         {:ok, harness} <- issue(project, params),
         {:ok, harness} <- WorkingCopies.report_root(harness, root) do
      Logger.info(
        "[Harnesses] #{harness.id} registered for project #{project_id} at #{harness.root}"
      )

      json(conn, %{
        working_copy_id: harness.id,
        project_id: harness.project_id,
        root: harness.root,
        label: harness.label
      })
    else
      {:error, {:missing, key}} ->
        error(conn, 400, "#{key} is required")

      {:error, :no_project} ->
        error(conn, 404, "No project with id #{params["project_id"]} in this local database")

      {:error, reason} ->
        error(conn, 422, "Could not register the harness: #{inspect(reason)}")
    end
  end

  defp issue(project, params) do
    scope = %Scope{active_project_id: project.id, active_project: project}

    WorkingCopies.issue(scope, params["harness_id"], label: params["label"])
  end

  defp fetch_project(project_id) do
    case Projects.get_project_by_id(project_id) do
      nil -> {:error, :no_project}
      project -> {:ok, project}
    end
  end

  defp require_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
