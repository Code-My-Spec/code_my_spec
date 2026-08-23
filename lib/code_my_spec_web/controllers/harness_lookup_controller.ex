defmodule CodeMySpecWeb.HarnessLookupController do
  @moduledoc """
  Where a harness is, answered by the side that knows.

  A hook arrives at the harness addressed to an id and nothing else. To serve
  it the harness needs a directory, and the only honest source for that is
  here: harness records belong to the server, and a copy of them on the harness
  would be a second store to reconcile — on a machine that may have no database
  at all, since a sprite runs standalone.

  So the harness asks. It already cannot answer a hook without the server —
  every decision is the server's — so needing it for the address costs no
  availability that was not already spent.

  `root` is what the harness reported about itself on its last join. It is
  data, never identity: two containers at `/workspace/app` report the same
  string and remain two harnesses, which is the whole reason the id is issued
  rather than derived.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @doc """
  Issue an id for a working copy, or recognise the one it already holds.

  Onboarding calls this. Without it a new checkout could not be onboarded at
  all: ids are minted on a channel join, and a harness only joins for copies it
  is already serving — which it learns by looking an id up. A checkout with no
  id could never acquire one.

  Idempotent on a presented id, so onboarding twice is one harness rather than
  two. Re-running it after a checkout moves updates where the server thinks it
  is, which is the point of recording that separately from identity.
  """
  def create(conn, params) do
    with {:ok, project_id} <- require_param(params, "project_id"),
         {:ok, root} <- require_param(params, "root"),
         {:ok, project} <- fetch_project(project_id),
         {:ok, harness} <- issue(project, params),
         {:ok, harness} <- WorkingCopies.report_root(harness, root) do
      json(conn, %{
        working_copy_id: harness.id,
        project_id: harness.project_id,
        root: harness.root
      })
    else
      {:error, {:missing, key}} ->
        conn |> put_status(400) |> json(%{error: "#{key} is required"})

      {:error, :no_project} ->
        conn |> put_status(404) |> json(%{error: "No project #{params["project_id"]}"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: "Could not issue: #{inspect(reason)}"})
    end
  end

  defp issue(project, params) do
    scope = %Scope{active_project_id: project.id, active_project: project}

    WorkingCopies.issue(
      scope,
      params["working_copy_id"] || params["harness_id"],
      label: params["label"]
    )
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

  def show(conn, %{"id" => id}) do
    case WorkingCopies.fetch(id) do
      {:ok, harness} ->
        json(conn, %{
          working_copy_id: harness.id,
          project_id: harness.project_id,
          root: harness.root,
          label: harness.label
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "No harness with id #{id}"})

      {:error, :invalid_id} ->
        conn
        |> put_status(400)
        |> json(%{error: "Not a valid harness id: #{inspect(id)}"})
    end
  end
end
