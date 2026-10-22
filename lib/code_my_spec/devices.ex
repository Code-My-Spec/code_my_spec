defmodule CodeMySpec.Devices do
  @moduledoc """
  The machines this account's working copies sit on.

  A device runs a harness; that harness serves one or more working copies; each
  copy runs one or more agents. This context owns the top level.

  ## Announcing, not registering

  `announce/3` has the same two shapes `WorkingCopies.issue/3` has: a machine
  presenting an id we already know is recognised, and one presenting an id we
  do not is created *using that id* — the machine minted it. The daemon writes
  the id to `~/.codemyspec/device.json` once and presents it forever after;
  see `CmsHarness.Device`.

  A missing or malformed id still mints a fresh one rather than failing.

  The machine mints the id because several daemons can share one box and one
  file; asking the server "who am I" on every announce raced. A self-picked id
  is not trusted as globally unique: one that collides with a *different*
  account's device is not handed that device — see `create_or_recognise/3`.

  ## A machine need not belong to anyone

  `announce/3` takes a scope that may carry no account and no project. A shared
  development box is not somebody's: several people work on it, it holds no
  checkout of its own, and requiring an account would attach it to whichever one
  announced first. It is issued an identity like any other machine.

  Scoping is unchanged where an account exists, and a nil account matches only
  other nil-account devices, so an accountless box recognising itself never
  becomes a route to somebody else's laptop.

  ## What is deliberately not here

  No `stop_device`. A device is somebody's machine; the server observes it and
  does not reach across to end anything on it. `destroy/2` removes only the
  record.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query, warn: false

  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Accounts.Member
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  The device for this id, or a new one created using it if the caller has none.

  `attrs` is what the machine says about itself — `:hostname` and `:kind` — and
  is applied on every announce, not only at creation, so a renamed or
  re-provisioned machine is described as it is now.

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

    case recognised(scope, device_id) do
      nil -> create_or_recognise(scope, device_id, attrs)
      device -> refresh(device, attrs)
    end
  end

  @doc """
  Associates an accountless local device with an authorized account.

  Only for trusted desktop callers that have already verified the desktop
  singleton and matched `device_id` against the server's recorded local identity.
  A client-supplied UUID alone is not proof of machine ownership. This does not
  move existing ownership, and must not be exposed as a generic claim API.
  """
  def associate_trusted_local_device(
        %Scope{user: %{id: _}, active_account_id: account_id} = scope,
        device_id
      )
      when is_binary(account_id) and is_binary(device_id) do
    with true <- Authorization.authorize(:read_account, scope, account_id),
         {:ok, id} <- Ecto.UUID.cast(device_id) do
      Repo.update_all(
        from(d in Device,
          where: d.id == ^id and is_nil(d.account_id) and d.kind == :local
        ),
        set: [account_id: account_id, updated_at: DateTime.utc_now()]
      )

      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def associate_trusted_local_device(_scope, _device_id), do: {:error, :forbidden}

  # One machine carries copies from every account its user belongs to, but the
  # row sits in whichever announced first. A token scoped to the user's other
  # account must still recognise it, or each heartbeat mints a fresh device with
  # an empty roster. Recognising never moves the row to the caller's account.
  defp recognised(%Scope{active_account_id: account_id} = scope, device_id) do
    existing(account_id, device_id) || members_device(scope, device_id)
  end

  defp members_device(%Scope{user_id: user_id}, device_id)
       when is_integer(user_id) and is_binary(device_id) do
    case Ecto.UUID.cast(device_id) do
      :error ->
        nil

      {:ok, id} ->
        accounts = from(m in Member, where: m.user_id == ^user_id, select: m.account_id)
        Repo.one(from(d in Device, where: d.id == ^id and d.account_id in subquery(accounts)))
    end
  end

  defp members_device(_scope, _device_id), do: nil

  defp refresh(device, attrs) do
    device |> Device.changeset(Map.delete(attrs, :account_id)) |> Repo.update()
  end

  # Not found under this account: a first announce of a self-minted id and two
  # daemons racing to create the same id look identical, so insert and, only on
  # a primary-key collision, re-check who holds it. An id that fails to cast
  # gets a server-minted device.
  defp create_or_recognise(scope, device_id, attrs) do
    case Ecto.UUID.cast(device_id) do
      {:ok, id} -> insert_or_reconcile(scope, id, attrs)
      :error -> %Device{} |> Device.changeset(attrs) |> Repo.insert()
    end
  end

  defp insert_or_reconcile(scope, id, attrs) do
    case id |> Device.new_changeset(attrs) |> Repo.insert() do
      {:ok, device} ->
        {:ok, device}

      {:error, changeset} ->
        if unique_id_violation?(changeset) do
          reconcile_after_conflict(scope, id, attrs)
        else
          {:error, changeset}
        end
    end
  end

  # The other insert won. This account's row → recognise it (the race between
  # two daemons on one machine). Another account's → its self-picked id
  # collided; issue a fresh server-minted id rather than hand over that row.
  defp reconcile_after_conflict(scope, id, attrs) do
    case recognised(scope, id) do
      nil -> %Device{} |> Device.changeset(attrs) |> Repo.insert()
      device -> refresh(device, attrs)
    end
  end

  defp unique_id_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # Scoped by account as well as id: the id is an input from a machine. A nil
  # account matches only accountless devices.
  defp existing(_account_id, nil), do: nil

  defp existing(account_id, device_id) when is_binary(device_id) do
    case Ecto.UUID.cast(device_id) do
      :error -> nil
      {:ok, id} -> Repo.one(scoped(id, account_id))
    end
  end

  # `is_nil/1`: `= NULL` is never true in SQL, so a shared box would get a new
  # identity on every restart.
  defp scoped(id, nil) do
    from(d in Device, where: d.id == ^id and is_nil(d.account_id))
  end

  defp scoped(id, account_id) do
    from(d in Device, where: d.id == ^id and d.account_id == ^account_id)
  end

  @doc """
  Add a dev box from a provider (story 1130), as `{:ok, device, token}`.

  Owners and admins only: `{:error, :forbidden}` for anyone else, checked here and
  not left to the page that offers the button. The token is minted here, shown
  once by the caller, and only its hash is kept. A box is announced `kind` by its
  provider (a `Workspaces.Runner`, resolved by the caller: Workspaces sits above
  Devices), since the provider is what knows what it runs on.
  """
  @spec add_dev_box(Scope.t(), map(), module() | nil) ::
          {:ok, Device.t(), String.t()}
          | {:error, :forbidden | :unknown_provider | Ecto.Changeset.t()}
  def add_dev_box(%Scope{active_account_id: account_id} = scope, params, provider)
      when is_binary(account_id) do
    with true <- scope.user != nil and Authorization.authorize(:manage_account, scope, account_id),
         {:ok, provider} <- known_provider(provider) do
      token = mint_token()

      attrs = %{
        label: String.trim(to_string(params["name"] || "")),
        provider: provider.id(),
        kind: provider.kind(),
        account_id: account_id,
        token_hash: hash_token(token)
      }

      case %Device{} |> Device.dev_box_changeset(attrs) |> Repo.insert() do
        {:ok, device} -> {:ok, device, token}
        {:error, changeset} -> {:error, changeset}
      end
    else
      false -> {:error, :forbidden}
      :unknown -> {:error, :unknown_provider}
    end
  end

  def add_dev_box(%Scope{}, _params, _provider), do: {:error, :forbidden}

  defp known_provider(nil), do: :unknown
  defp known_provider(provider), do: {:ok, provider}

  defp mint_token, do: "cbt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  The dev box this token belongs to, or nil. Marks it connected: the first
  sign-in is what turns "Never connected" into "Connected", and every later one
  refreshes it. Another box's token never resolves to this one.
  """
  @spec sign_in_with_token(String.t() | nil) :: Device.t() | nil
  def sign_in_with_token(token) when is_binary(token) and token != "" do
    hash = hash_token(token)

    case Repo.one(from(d in Device, where: d.token_hash == ^hash and is_nil(d.token_revoked_at))) do
      nil ->
        nil

      %Device{} = device ->
        {:ok, device} = device |> Device.token_used_changeset(DateTime.utc_now()) |> Repo.update()
        broadcast(device, {:dev_box_connected, device.id})
        device
    end
  end

  def sign_in_with_token(_token), do: nil

  @doc """
  Revoke a dev box's token (story 1131). Owners and admins only; the box's token
  stops signing in, and nothing else on the account is touched.
  """
  @spec revoke_dev_box(Scope.t(), String.t()) ::
          {:ok, Device.t()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def revoke_dev_box(%Scope{active_account_id: account_id} = scope, id)
      when is_binary(account_id) do
    with true <- scope.user != nil and Authorization.authorize(:manage_account, scope, account_id),
         %Device{} = box <- get_device(scope, id),
         true <- Device.dev_box?(box) do
      case box |> Device.revoked_changeset(DateTime.utc_now()) |> Repo.update() do
        {:ok, box} ->
          broadcast(box, {:dev_box_revoked, box.id})
          {:ok, box}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  def revoke_dev_box(%Scope{}, _id), do: {:error, :forbidden}

  @doc """
  The dev box with this id whose token has not been revoked, or nil. For an
  access token issued to a box: it holds for as long as its box does.
  """
  @spec active_dev_box(String.t() | nil) :: Device.t() | nil
  def active_dev_box(id) when is_binary(id) do
    case Repo.get(Device, id) do
      %Device{token_revoked_at: nil} = box -> if Device.dev_box?(box), do: box
      _ -> nil
    end
  end

  def active_dev_box(_id), do: nil

  @doc """
  A box's harness joined a project channel: tell the account's page, so what it
  reported (a preview address) shows without a reload.
  """
  @spec box_joined(String.t() | nil) :: :ok
  def box_joined(device_id) when is_binary(device_id) do
    case Repo.get(Device, device_id) do
      %Device{} = box -> broadcast(box, {:dev_box_connected, box.id})
      nil -> :ok
    end
  end

  def box_joined(_device_id), do: :ok

  @doc """
  Give a cloud box the routine that starts it (story 1136). Owners and admins
  only. The token is stored encrypted and never shown again.
  """
  @spec set_fire_token(Scope.t(), String.t(), map()) ::
          {:ok, Device.t()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def set_fire_token(%Scope{active_account_id: account_id} = scope, id, params)
      when is_binary(account_id) do
    with true <- scope.user != nil and Authorization.authorize(:manage_account, scope, account_id),
         %Device{} = box <- get_device(scope, id),
         true <- Device.dev_box?(box) do
      box
      |> Device.fire_changeset(%{
        fire_routine_id: String.trim(to_string(params["routine_id"] || "")),
        fire_token: String.trim(to_string(params["token"] || ""))
      })
      |> Repo.update()
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  def set_fire_token(%Scope{}, _id, _params), do: {:error, :forbidden}

  @doc "Whether this box can be started by firing its routine."
  @spec startable?(Device.t()) :: boolean()
  def startable?(%Device{fire_routine_id: routine, fire_token: token}),
    do: is_binary(routine) and routine != "" and is_binary(token) and token != ""

  @doc "Subscribe to changes to this account's dev boxes."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(account_id) when is_binary(account_id),
    do: Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(account_id))

  defp broadcast(%Device{account_id: account_id}, message) when is_binary(account_id),
    do: Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(account_id), message)

  defp broadcast(_device, _message), do: :ok

  defp topic(account_id), do: "devices:#{account_id}"

  @doc """
  The announce of a dev box that signed in with its token: it is told who it is
  whatever id it presents, and says what it runs on.
  """
  @spec announce_box(Device.t(), map()) :: {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def announce_box(%Device{} = box, attrs) do
    box
    |> Device.changeset(
      %{hostname: attrs[:hostname], last_seen_at: DateTime.utc_now()}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )
    |> Repo.update()
  end

  @doc """
  Every device on this account, most recently seen first.

  The order is the operator's default view: the machine you were just working on
  is the one you are asking about.
  """
  @spec list_devices(Scope.t()) :: [Device.t()]
  def list_devices(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    # A copy names its device; a device does not carry its copies. Ask
    # `WorkingCopies.ids_by_device/1` for them.
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
  An announced machine accessible to this harness, or nil.

  A user's machine can serve projects across their account memberships without
  moving its device record or changing their selected account. Scopes without
  a user remain limited to their active account. This lookup never creates or
  refreshes a device.
  """
  @spec get_harness_device(Scope.t(), String.t()) :: Device.t() | nil
  def get_harness_device(%Scope{user_id: user_id} = scope, id) when is_integer(user_id),
    do: members_device(scope, id)

  def get_harness_device(%Scope{} = scope, id), do: get_device(scope, id)

  @doc """
  The tunnel a machine's harness runs, as `{:ok, %{tunnel_id, tunnel_secret}}`,
  or `:error` when it holds none. Unscoped: the caller already holds a working
  copy on this machine, which is what decides it may ask.
  """
  @spec tunnel(Ecto.UUID.t() | nil) :: {:ok, map()} | :error
  def tunnel(device_id) when is_binary(device_id) do
    case Repo.get(Device, device_id) do
      %Device{preview_tunnel_id: id, preview_tunnel_secret: secret}
      when is_binary(id) and is_binary(secret) ->
        {:ok, %{tunnel_id: id, tunnel_secret: secret}}

      _ ->
        :error
    end
  end

  def tunnel(_device_id), do: :error

  @doc "Record the tunnel a machine's harness runs."
  @spec record_tunnel(Ecto.UUID.t(), map()) :: {:ok, Device.t()} | {:error, term()}
  def record_tunnel(device_id, %{tunnel_id: id, tunnel_secret: secret})
      when is_binary(device_id) do
    case Repo.get(Device, device_id) do
      nil ->
        {:error, :no_such_device}

      device ->
        device
        |> Device.tunnel_changeset(%{preview_tunnel_id: id, preview_tunnel_secret: secret})
        |> Repo.update()
    end
  end

  @doc """
  Record that this machine is alive, because something on it just proved it.

  Split from `announce/3` as `WorkingCopies.mark_alive/1` is from `issue/3`:
  announcing happens once when the harness comes up; this answers "you are
  still here". Conflating them made `last_seen_at` mean "last reboot".

  Best-effort: a machine that cannot be marked alive is not a reason to refuse
  a hook.
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
  Record that this device's harness just disconnected for the last of its
  working copies -- the moment it went down, not merely a recent activity
  timestamp (story 1138).

  Best-effort, like `mark_alive/1`: a device that cannot be marked down is
  not a reason to fail a channel's own shutdown.
  """
  @spec mark_down(Device.t() | Ecto.UUID.t()) :: :ok
  def mark_down(%Device{} = device) do
    device
    |> Device.went_down_changeset(DateTime.utc_now())
    |> Repo.update()

    :ok
  end

  def mark_down(device_id) when is_binary(device_id) do
    case Repo.get(Device, device_id) do
      nil -> :ok
      device -> mark_down(device)
    end
  end

  @doc """
  Record what a machine is carrying, from the working copy that reported it.

  The figure belongs to the box rather than the checkout — two copies on one
  machine share its processors. Stamped with its arrival time, because a load
  figure with no age should not be acted on.

  Best-effort, like `mark_alive/1`: a checkout with no device is ordinary for
  an older harness.
  """
  @spec record_load(Ecto.UUID.t() | nil, map()) :: :ok
  def record_load(nil, load) when is_map(load), do: :ok

  def record_load(device_id, load) when is_map(load) do
    Device
    |> Repo.get(device_id)
    |> write_load(load)
  end

  defp write_load(nil, _load), do: :ok

  defp write_load(%Device{} = device, load) do
    device
    |> Device.changeset(%{load: load, load_reported_at: DateTime.utc_now()})
    |> Repo.update()

    :ok
  end

  @doc """
  Remove a machine.

  Its working copies are deleted with it (`working_copies.device_id` cascades):
  a checkout is a projection of a directory that no longer exists. Records of
  work done on it — `agents`, `issues`, `problems` — are `SET NULL` and
  survive. Destroying a device with copies attached deletes those copies.
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
