defmodule CodeMySpecWeb.DeviceController do
  @moduledoc """
  A machine announcing itself.

  The one route a harness needs before it has anything else. Every other
  device-facing surface is per working copy — `harness_project:<project_id>` is
  a channel per checkout — and a machine is a machine before it has a checkout
  on it. So onboarding cannot ride the channel: at boot there is no project to
  name, and waiting for one would mean a box with nothing checked out never
  appears at all.

  Plain HTTP for the same reason `HarnessLookupController` is: this is the side
  that knows, reached by a client that holds only a credential and whatever it
  wrote down last time.

  ## Both credentials, because both kinds of machine exist

  It sits behind `Plugs.DeployKeyOrOAuth`, which takes a user's OAuth token or a
  project's deploy key. That is not a convenience — it is the same distinction
  `kind` records. A laptop has a signed-in user; a sprite has no user at all and
  only ever holds a deploy key. A route that took one of them would onboard half
  the fleet.

  ## Announcing repeats, and carries what the machine can see

  A harness re-announces on a heartbeat, so this doubles as the device's proof
  of life and as where it reports which of its checkouts are still on disk —
  `working_copies`, a map of id to boolean.

  That report belongs here and not on a channel, because of the scoping. A
  device is account-scoped and a working copy is project-scoped, so "the copies
  I can see" spans projects by nature; `harness_project:<project_id>` is a
  channel per checkout and could only ever carry claims about its own. This is
  the one surface with the right shape for a statement about a whole machine.

  What it does *not* let a machine do is talk about copies that are not its own
  — `WorkingCopies.observe_paths/2` is scoped to `device_id`, so an id from
  another box is ignored rather than believed.

  ## Announcing is idempotent, and unrecognised is not an error

  A machine presents the id it holds, or none. An id we do not recognise — from
  another account, or from a database that has been rebuilt — puts the machine
  in exactly the position of one presenting nothing: it needs an identity. So it
  is issued its own rather than refused. Refusing would leave a real machine with
  no way to onboard, and the failure would be silent at boot on somebody else's
  hardware.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Devices
  alias CodeMySpec.WorkingCopies

  @doc """
  Issue or recognise this machine.

  Answers `device_id` either way, which is the only thing the caller needs: it
  writes that down and presents it next time.
  """
  def create(conn, params) do
    case Devices.announce(scope(conn), params["device_id"], attrs(params)) do
      {:ok, device} ->
        WorkingCopies.observe_paths(device, observations(params["working_copies"]))
        json(conn, %{device_id: device.id})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(changeset.errors)})
    end
  end

  # The account this machine belongs to, if it belongs to one.
  #
  # A device is account-scoped and a working copy is project-scoped, so a
  # machine announcing itself names an account at most — never a project. It has
  # no checkout yet, which is the whole reason this route exists rather than the
  # channel.
  #
  # And it may name nothing. A shared development box belongs to no account:
  # several people work on it, and forcing one would attach it to whichever
  # announced first. `Devices.announce/3` takes a scope with a nil account, and
  # a nil account matches only other accountless devices — so a shared box
  # recognising itself never becomes a route to somebody's laptop.
  defp scope(conn), do: conn.assigns[:current_scope] || %CodeMySpec.Users.Scope{}

  # Only what a machine can honestly say about itself. `kind` is refused rather
  # than coerced: an unrecognised value is a client this server does not
  # understand, and recording it as `:local` would make a sprite read as
  # somebody's laptop — the one distinction the field exists for.
  defp attrs(params) do
    %{hostname: params["hostname"], kind: kind(params["kind"])}
  end

  defp kind("local"), do: :local
  defp kind("cloud"), do: :cloud
  defp kind(_other), do: nil

  # What the harness says it can see, as `id => present?`.
  #
  # Only real booleans count. A JSON body is whatever the caller sent, and a
  # string `"false"` is truthy in Elixir — read loosely, a malformed report
  # would mark every copy on the machine present and silently clear warnings
  # that were correct. Anything that is not `true` or `false` is dropped, which
  # puts it in the same position as a copy the harness never mentioned.
  defp observations(map) when is_map(map) do
    for {id, present?} <- map, is_binary(id), is_boolean(present?), into: %{}, do: {id, present?}
  end

  defp observations(_other), do: %{}
end
