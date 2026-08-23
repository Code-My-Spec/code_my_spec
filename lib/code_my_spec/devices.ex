defmodule CodeMySpec.Devices do
  @moduledoc """
  The machines this account's working copies sit on.

  A device runs a harness; that harness serves one or more working copies; each
  copy runs one or more agents. This context owns the top level.

  ## Announcing, not registering

  `announce/2` has the same two shapes `WorkingCopies.issue/3` has, for the same
  reason: a machine that has never connected presents `nil` and is issued an id,
  and one that has presents its id and is recognised. The daemon writes the id
  to `~/.codemyspec/device.json` and presents it forever after.

  An id naming no device mints a new one rather than failing. The alternative is
  a machine that cannot serve until somebody deletes a file it has no reason to
  suspect — and the cost of a new id is that its copies re-attach on their next
  join, which they do anyway.

  ## Why the server issues it

  Every client-derived identity fails the case that matters. A hostname is
  generated for exactly the containers that collide. A MAC address does not
  survive a re-image. A path is not identity at all. This is the same argument
  that made `WorkingCopies.issue/3` server-side, one level up, and it fails the
  same way if you get it wrong: two machines answering as one, silently.

  ## What is deliberately not here

  No `stop_device`, no `delete_device`. A device is somebody's machine; the
  server observes it and does not reach across to end anything on it. Same
  decision the working-copies page makes about agents, for the same reason.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  The device for this id, or a new one if the caller has none.

  `attrs` is what the machine says about itself — `:hostname` and `:kind` — and
  is applied on every announce, not only at creation. A laptop that is
  re-provisioned as a sprite, or renamed, says so on its next connection, and a
  record that only ever took the first answer would describe the machine as it
  was when it first appeared.

  A label a person chose is never overwritten from here: the machine does not
  know what somebody decided to call it.
  """
  @spec announce(Scope.t(), String.t() | nil, map()) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def announce(%Scope{active_account_id: account_id}, device_id, attrs \\ %{})
      when is_binary(account_id) do
    attrs =
      attrs
      |> Map.take([:hostname, :kind])
      |> Map.put(:account_id, account_id)
      |> Map.put(:last_seen_at, DateTime.utc_now())

    case existing(account_id, device_id) do
      nil -> %Device{} |> Device.changeset(attrs) |> Repo.insert()
      device -> device |> Device.changeset(attrs) |> Repo.update()
    end
  end

  # Scoped by account as well as id. The id arrives from a machine and is
  # therefore an input: without the account check, one account's daemon
  # presenting another's device id would be handed it.
  defp existing(_account_id, nil), do: nil

  defp existing(account_id, device_id) when is_binary(device_id) do
    case Ecto.UUID.cast(device_id) do
      :error -> nil
      {:ok, id} -> Repo.get_by(Device, id: id, account_id: account_id)
    end
  end

  @doc """
  Every device on this account, most recently seen first.

  The order is the operator's default view: the machine you were just working on
  is the one you are asking about.
  """
  @spec list_devices(Scope.t()) :: [Device.t()]
  def list_devices(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    from(d in Device,
      where: d.account_id == ^account_id,
      order_by: [desc_nulls_last: d.last_seen_at]
    )
    |> Repo.all()
  end

  def list_devices(%Scope{}), do: []

  @doc "One device on this account, or nil. Never an unscoped lookup by id."
  @spec get_device(Scope.t(), String.t()) :: Device.t() | nil
  def get_device(%Scope{active_account_id: account_id}, id) when is_binary(account_id),
    do: existing(account_id, id)

  def get_device(%Scope{}, _id), do: nil

  @doc """
  Attach a working copy to the machine it is on.

  Called on join, when the daemon says which device it is announcing from. A
  copy that moves machines — a repository cloned to a new laptop under the same
  id — re-attaches rather than being refused, because the copy's identity is its
  own and does not belong to the box.
  """
  @spec attach(WorkingCopy.t(), Device.t() | nil) ::
          {:ok, WorkingCopy.t()} | {:error, Ecto.Changeset.t()}
  def attach(%WorkingCopy{} = working_copy, nil), do: {:ok, working_copy}

  def attach(%WorkingCopy{device_id: id} = working_copy, %Device{id: id}),
    do: {:ok, working_copy}

  def attach(%WorkingCopy{} = working_copy, %Device{} = device) do
    working_copy
    |> WorkingCopy.changeset(%{device_id: device.id})
    |> Repo.update()
  end

  @doc """
  Give a device a name a person chose.

  Blank clears it rather than storing an empty string, so the display falls back
  to the hostname instead of showing nothing — the same rule
  `WorkingCopies.relabel/3` follows.
  """
  @spec relabel(Scope.t(), Device.t(), String.t()) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t() | :not_yours}
  def relabel(
        %Scope{active_account_id: account_id},
        %Device{account_id: account_id} = device,
        label
      ) do
    device
    |> Device.changeset(%{label: normalize_label(label)})
    |> Repo.update()
  end

  def relabel(%Scope{}, %Device{}, _label), do: {:error, :not_yours}

  defp normalize_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_label(_label), do: nil
end
