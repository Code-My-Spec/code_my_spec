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
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel

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
        harness_id: harness.id,
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

  # `device` and `root` go through, not only the label.
  #
  # `WorkingCopies.issue/3` recognises a checkout by `{project, device, root}`,
  # so withholding two of the three left this endpoint unable to recognise
  # anything: onboarding the same checkout twice minted two rows, and both were
  # device-less because the device is written at mint. The channel join has
  # passed all three for a while; this path is where the gap survived.
  defp issue(project, params) do
    scope = %Scope{active_project_id: project.id, active_project: project}

    WorkingCopies.issue(
      scope,
      params["working_copy_id"] || params["harness_id"],
      label: params["label"],
      device: params["device_id"],
      root: params["root"]
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
          harness_id: harness.id,
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

  @doc """
  The address this working copy's preview answers on, provisioning it if it has
  none.

  Story 968. Onboarding calls this and writes what comes back into the
  checkout's own config, which is where the harness reads it and reports it from.

  ## Why the server does this and onboarding does not

  Onboarding ships in `client_utils` so that a generated application can onboard
  itself — story 891's rule, and the reason a preview cannot be provisioned on
  that side. Creating a tunnel needs our Cloudflare credential, and a credential
  in every generated application is a credential every customer has. So the
  caller asks and the server, which already holds it, answers.

  Same reasoning as `create/2` above: the harness cannot do this alone, and it
  already cannot function without the server, so asking costs no availability
  that was not already spent.

  ## Refusals are answers, not failures

  A checkout that is not the project's main one, and a server with no Cloudflare
  account configured, both get a status and a reason rather than an error the
  caller should abort over. Onboarding does many things and a preview is one of
  them; a copy that comes back fully configured except for a preview is far more
  useful than a copy that refused to finish.
  """
  def preview(conn, %{"id" => id}) do
    with {:ok, copy} <- WorkingCopies.fetch(id),
         {:ok, credentials} <- PreviewTunnel.ensure(copy) do
      json(conn, %{
        # Derived the same way `ensure/1` records it rather than read back off
        # the row we fetched a moment ago, which still holds whatever was there
        # before this call provisioned anything. Scheme and port come from the
        # same configuration, so dev's `:4010` is not lost on the way out.
        preview_url: PreviewAddress.url(copy.id),
        hostname: credentials.hostname,
        tunnel_id: credentials.tunnel_id,
        account_tag: credentials.account_tag,
        tunnel_secret: credentials.tunnel_secret,
        # Which origin may frame this app. Returned rather than left to the
        # checkout to guess: getting it wrong refuses the pane silently, and the
        # server is the thing doing the framing so it is the thing that knows.
        embedder: credentials.embedder
      })
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "No harness with id #{id}"})

      {:error, :invalid_id} ->
        conn |> put_status(400) |> json(%{error: "Not a valid harness id: #{inspect(id)}"})

      # 409 rather than 403: nothing is wrong with the caller's credential, and
      # nothing about this copy is broken. It is simply not the one the project's
      # preview runs from, and at most one copy ever is.
      {:error, :not_the_main_copy} ->
        conn
        |> put_status(409)
        |> json(%{
          error: "not_the_main_copy",
          detail:
            "This checkout is not the one this project's preview runs from, so it " <>
              "was not given an address. Every worktree can run the app and only one " <>
              "of them is the project's."
        })

      # 503: the caller did nothing wrong and retrying later may well work. A
      # deployment with no Cloudflare account configured cannot make tunnels for
      # anybody, which is an operator's problem rather than this checkout's.
      {:error, :no_cloudflare_account_id} ->
        conn
        |> put_status(503)
        |> json(%{
          error: "previews_not_configured",
          detail: "This server has no Cloudflare account configured, so it cannot make tunnels."
        })

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{error: "preview_unavailable", detail: inspect(reason)})
    end
  end
end
