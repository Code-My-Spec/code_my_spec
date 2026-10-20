defmodule CodeMySpecWeb.DeviceController do
  @moduledoc """
  A machine announcing itself: the one route a harness needs before it has a
  checkout (and so before it has a `harness_project:<id>` channel).

  Behind `Plugs.DeployKeyOrOAuth`: a laptop holds a user's OAuth token, a
  sprite only a deploy key.

  Repeated on a heartbeat. The request reports which of this device's checkouts
  are on disk (`working_copies`, `id => boolean`; ids from other devices are
  ignored). The reply carries the device id, every copy attached to it
  (`id => root`, so a restarted harness knows where to look), and, for a
  `:local` device with an account, local projects pending generation.

  Idempotent: a client-minted id we do not know creates the row with that id;
  an id already naming a device the caller cannot reach (another account,
  not one of the user's) gets a fresh one instead.

  See knowledge/web, "Device announce".
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Devices
  alias CodeMySpec.Intake
  alias CodeMySpec.Projects
  alias CodeMySpec.WorkingCopies

  @doc """
  Issue or recognise this machine.

  Answers `device_id` either way, which is the only thing the caller needs: it
  writes that down and presents it next time.
  """
  def create(%Plug.Conn{assigns: %{box_device: box}} = conn, params) do
    # Signed in with a dev box's own token: it is that box, whatever id it presents.
    {:ok, device} = CodeMySpec.Devices.announce_box(box, %{hostname: params["hostname"]})
    WorkingCopies.observe_paths(device, observations(params["working_copies"]))

    json(conn, %{
      device_id: device.id,
      working_copies: WorkingCopies.list_on_device(device),
      pending_local_projects: []
    })
  end

  def create(conn, params) do
    scope = scope(conn)

    case Devices.announce(scope, params["device_id"], attrs(params)) do
      {:ok, device} ->
        WorkingCopies.observe_paths(device, observations(params["working_copies"]))

        json(conn, %{
          device_id: device.id,
          working_copies: WorkingCopies.list_on_device(device),
          pending_local_projects: pending_local_projects(scope, device)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(changeset.errors)})
    end
  end

  # Confirmed local projects with no checkout yet, so a running harness picks
  # one up on its next heartbeat. The deploy key is minted here: the onboard
  # task has no other way to get one. Only for a `:local` device with an
  # account; a shared box or a sprite is never offered one.
  defp pending_local_projects(%{active_account_id: account_id}, %{kind: :local})
       when is_binary(account_id) do
    for plan <- Intake.pending_local_projects(account_id) do
      {:ok, project} = Projects.ensure_deploy_key(scope_for(plan), plan.project)

      %{
        "id" => project.id,
        "name" => project.name,
        "app_name" => Projects.app_name(project),
        "deploy_key" => project.deploy_key
      }
    end
  end

  defp pending_local_projects(_scope, _device), do: []

  defp scope_for(%{account_id: account_id, project_id: project_id}) do
    %CodeMySpec.Users.Scope{active_account_id: account_id, active_project_id: project_id}
  end

  # The machine's account, or none (a shared box). A nil account matches only
  # other accountless devices in `Devices.announce/3`.
  defp scope(conn), do: conn.assigns[:current_scope] || %CodeMySpec.Users.Scope{}

  # An unrecognised `kind` is nil (refused), never coerced to `:local`.
  defp attrs(params) do
    %{hostname: params["hostname"], kind: kind(params["kind"])}
  end

  defp kind("local"), do: :local
  defp kind("cloud"), do: :cloud
  defp kind(_other), do: nil

  # `id => present?`. Only real booleans count (a string "false" is truthy);
  # anything else is dropped, as if unmentioned.
  defp observations(map) when is_map(map) do
    for {id, present?} <- map, is_binary(id), is_boolean(present?), into: %{}, do: {id, present?}
  end

  defp observations(_other), do: %{}
end
