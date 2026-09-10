defmodule CodeMySpec.Devices do
  @moduledoc """
  The machines this account's working copies sit on.

  A device runs a harness; that harness serves one or more working copies; each
  copy runs one or more agents. This context owns the top level.

  ## Announcing, not registering

  `announce/2` has the same two shapes `WorkingCopies.issue/3` has: a machine
  presenting an id we already know is recognised, and one presenting an id we
  do not is created *using that id* — the machine minted it, this just takes
  its word. The daemon writes the id to `~/.codemyspec/device.json` once and
  presents it forever after; see `CmsHarness.Device`.

  A missing or malformed id still mints a fresh one rather than failing —
  reached only by a client too old to send one, or one that could not
  determine anything about the machine it is on at all.

  ## Why the machine mints it, not the server

  This used to be reversed, on the argument that every client-derived
  identity fails the case that matters — a generated container hostname, a
  MAC address that does not survive a re-image, a path that is not identity
  at all. The argument was sound; the conclusion did not follow. What it
  actually ruled out was *trusting* a client-derived id as globally unique,
  not minting one client-side at all.

  Server-issued turned out to have its own failure the client-side argument
  missed: the id lives in one file per machine
  (`~/.codemyspec/device.json`), and more than one daemon can run on one
  box — a laptop's own dev harness alongside a separately installed
  packaged service, each independently re-announcing on its own schedule.
  Two writers sharing one file with no coordination raced it: each announce
  asked the server "who am I", each got handed back whatever the *other*
  daemon had most recently been told, and the file's content changed every
  few minutes with no daemon ever settling on an identity long enough for a
  channel join to still be holding it a moment later.

  Asking a machine to assert its own identity instead — once, and only once
  — removes the question that was being asked repeatedly and racily. The id
  a fresh machine picks still is not guaranteed globally unique the way a
  server-minted one was, so a presented id that collides with a *different*
  account's device is not handed that device — see `create_or_recognise/3`.
  What changed is who is trusted to hold the record of "who am I" between
  asks: the machine's own file, not a question re-asked of the server on
  every announce.

  ## A machine need not belong to anyone

  `announce/3` takes a scope that may carry no account and no project. A shared
  development box is not somebody's: several people work on it, it holds no
  checkout of its own, and requiring an account would attach it to whichever one
  announced first. It is issued an identity like any other machine.

  Scoping is unchanged where an account exists. This widens what may be stored,
  not who may read it — and a nil account matches only other nil-account
  devices, so an accountless box recognising itself never becomes a route to
  somebody else's laptop.

  ## What is deliberately not here

  No `stop_device`, no `delete_device`. A device is somebody's machine; the
  server observes it and does not reach across to end anything on it. Same
  decision the working-copies page makes about agents, for the same reason.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Repo,
      CodeMySpec.Users,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  import Ecto.Query, warn: false

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  The device for this id, or a new one created using it if the caller has none.

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
  def announce(%Scope{} = scope, device_id, attrs \\ %{}) do
    account_id = scope.active_account_id

    attrs =
      attrs
      |> Map.take([:hostname, :kind])
      |> Map.put(:account_id, account_id)
      |> Map.put(:last_seen_at, DateTime.utc_now())

    case existing(account_id, device_id) do
      nil -> create_or_recognise(account_id, device_id, attrs)
      device -> device |> Device.changeset(attrs) |> Repo.update()
    end
  end

  # Not found under this account, but the id it presented still matters: a
  # machine that minted its own id and is announcing for the first time looks
  # identical, from here, to two daemons on the same box racing to create the
  # same id at once. Both are handled by trying the insert and, only on a
  # primary-key collision, re-checking who actually holds it now.
  #
  # A well-formed id that fails to cast is not this machine's fault, so it
  # still gets a device — just one minted here instead, same as the
  # never-presented-anything case always has.
  defp create_or_recognise(account_id, device_id, attrs) do
    case Ecto.UUID.cast(device_id) do
      {:ok, id} -> insert_or_reconcile(account_id, id, attrs)
      :error -> %Device{} |> Device.changeset(attrs) |> Repo.insert()
    end
  end

  defp insert_or_reconcile(account_id, id, attrs) do
    case id |> Device.new_changeset(attrs) |> Repo.insert() do
      {:ok, device} ->
        {:ok, device}

      {:error, changeset} ->
        if unique_id_violation?(changeset) do
          reconcile_after_conflict(account_id, id, attrs)
        else
          {:error, changeset}
        end
    end
  end

  # The id is already somebody's row by the time we look again. If it is
  # *this* account's — the ordinary shape of the race, two daemons on one
  # machine both announcing a brand-new id at once — recognise it: the other
  # insert won, and losing a race to create your own device is not a reason
  # to be refused it. If it belongs to a different account, this machine's
  # self-picked id collided with somebody else's device entirely — vanishingly
  # unlikely, but not a reason to hand this machine's announce to that
  # account's row — so a fresh, server-minted id is issued instead, same as
  # the no-id-presented case.
  defp reconcile_after_conflict(account_id, id, attrs) do
    case existing(account_id, id) do
      nil -> %Device{} |> Device.changeset(attrs) |> Repo.insert()
      device -> device |> Device.changeset(attrs) |> Repo.update()
    end
  end

  defp unique_id_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # Scoped by account as well as id. The id arrives from a machine and is
  # therefore an input: without the account check, one account's daemon
  # presenting another's device id would be handed it.
  #
  # A nil account matches only devices that are themselves accountless. A shared
  # box recognises itself across restarts; it does not become a way to reach
  # somebody's laptop by presenting its id with no credentials attached.
  defp existing(_account_id, nil), do: nil

  defp existing(account_id, device_id) when is_binary(device_id) do
    case Ecto.UUID.cast(device_id) do
      :error -> nil
      {:ok, id} -> Repo.one(scoped(id, account_id))
    end
  end

  # `is_nil/1` rather than `account_id: nil`, which Ecto refuses outright — and
  # is right to. `= NULL` is never true in SQL, so a nil account compared that
  # way would match no row and a shared box would be issued a new identity on
  # every restart, quietly.
  defp scoped(id, nil) do
    from(d in Device, where: d.id == ^id and is_nil(d.account_id))
  end

  defp scoped(id, account_id) do
    from(d in Device, where: d.id == ^id and d.account_id == ^account_id)
  end

  @doc """
  Every device on this account, most recently seen first.

  The order is the operator's default view: the machine you were just working on
  is the one you are asking about.
  """
  @spec list_devices(Scope.t()) :: [Device.t()]
  def list_devices(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    # The copies come with it. Whether a machine is reachable is answered by
    # asking `HarnessRegistry` whether any of its working copies holds a
    # channel, so a caller without them cannot tell a quiet machine from an
    # unreachable one — and `%Ecto.Association.NotLoaded{}` reaching
    # `Enum.any?/2` raises rather than reading as "no copies", which is the
    # better failure but still a failure.
    from(d in Device,
      where: d.account_id == ^account_id,
      order_by: [desc_nulls_last: d.last_seen_at],
      preload: [:working_copies]
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
  Record that this machine is alive, because something on it just proved it.

  Split from `announce/3` for the reason `WorkingCopies.mark_alive/1` is split
  from `issue/3`: announcing answers "who are you" and happens once when the
  harness comes up, while this answers "you are still here". Conflating them
  made `last_seen_at` mean "when did this box last reboot", so every machine
  read as "Last seen" two minutes after starting — including one whose harness
  was connected and serving at that moment.

  Best-effort on purpose. This is bookkeeping alongside a request that has real
  work to do, and a machine that cannot be marked alive is not a reason to
  refuse a hook.
  """
  @spec mark_alive(Device.t() | Ecto.UUID.t() | nil) :: :ok
  def mark_alive(%Device{} = device) do
    device
    |> Device.changeset(%{last_seen_at: DateTime.utc_now()})
    |> Repo.update()

    :ok
  end

  def mark_alive(nil), do: :ok

  def mark_alive(device_id) when is_binary(device_id) do
    case Ecto.UUID.cast(device_id) do
      :error -> :ok
      {:ok, id} -> id |> then(&Repo.get(Device, &1)) |> mark_alive()
    end
  end

  @doc """
  Remove a machine, leaving its working copies behind.

  Destroying is a real act for a sprite, and uninstalling CMS from a laptop
  amounts to the same thing: the machine stops existing as far as this system is
  concerned. The checkouts it served do not — they happened, and were worked in.

  So `working_copies.device_id` nullifies rather than cascading, and those rows
  land in exactly the state of a copy that never reported a machine. The two
  histories are indistinguishable from the row, which is correct: nothing can
  tell them apart, so nothing should claim to.
  """
  @spec destroy(Scope.t(), Device.t()) :: {:ok, Device.t()} | {:error, :not_yours}
  def destroy(%Scope{active_account_id: account_id}, %Device{account_id: account_id} = device),
    do: Repo.delete(device)

  def destroy(%Scope{}, %Device{}), do: {:error, :not_yours}

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
