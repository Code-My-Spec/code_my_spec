defmodule CmsHarness.Device do
  @moduledoc """
  This machine's identity, established when the harness comes up.

  One file, `~/.codemyspec/device.json`, beside `harness_secret` and
  deliberately **not** inside any working copy.

  ## Why the install and not the checkout

  Two reasons, and the second is the one that would have bitten.

  A machine is a machine whether or not it has a checkout on it. Announcing per
  working copy — which is what the first cut of this did, on the
  `harness_project:` join — makes a box appear only once something is checked
  out on it, and mints a *new* machine per checkout after that. Eight worktrees
  on one laptop would have been eight laptops.

  And `.cms_harness.json` lives in the repository, so it clones. Story 891's
  criterion 2353 exists because of that: a clone inheriting the identity of the
  copy it came from. A file outside every checkout cannot be cloned at all,
  which turns that whole class into something the placement handles rather than
  something a guard has to catch.

  ## The id is minted here, not issued by the server

  This used to be reversed — the machine announced what it held, or nothing,
  and the server was the one to say who it was. See `CodeMySpec.Devices`'
  moduledoc for why that turned out to have its own failure: the identity
  lived in one file that more than one daemon on a single box could hold open
  at once, each asking the server "who am I" on its own schedule and each
  overwriting the file with whatever it was told. A question re-asked
  repeatedly, with no coordination between the askers, does not have a stable
  answer.

  So the machine decides once, for itself, and never asks again: `fresh_id/0`
  runs only the first time `recorded_id/0` finds nothing, `write/1` refuses to
  move an id already on file, and a server reply that disagrees is logged and
  ignored rather than adopted (see `announce/1`'s "This machine decides who it
  is, once"). A hostname is still generated for exactly the containers that
  would collide, and a bare filesystem path is still not identity — those
  arguments hold — but a network interface's hardware address is a real
  exception, which is what `fresh_id/0` prefers before falling back to a
  locally-generated random id.

  ## Failure is soft on purpose, and does not cost the identity

  A harness that cannot reach the server still has work to do: it watches files,
  runs analyzers and answers hooks against whatever it already knows. Refusing
  to boot because a machine could not announce itself would trade a cosmetic gap
  in a list for the whole harness, so this logs and carries on.

  It carries on *knowing who it is*. The id is written when it is minted rather
  than when a reply arrives — minting and recording are one act, because the id
  is this machine's own and there is nothing for a server to confirm before it
  counts. Deferring the write until the reply meant an unreachable server left
  the machine holding no id at all, so the join payload `ChannelClient` builds
  from `recorded_id/0` went out empty and came back "This harness did not say
  which machine it is on" — a network failure wearing an identity failure's
  error message (3bc0f683).
  """

  require Logger

  alias CmsHarness.Config
  alias CmsHarness.Device.Client
  alias CmsHarness.Token

  @default_path "~/.codemyspec/device.json"

  @doc """
  Announce this machine and keep the identity it is issued.

  Returns `{:ok, %{device_id: id, working_copies: %{id => root}}}`, or
  `{:error, reason}` when the server could not be reached or refused. Safe to
  call on every boot: presenting the id we already hold is how the server
  recognises the machine rather than minting another.

  `working_copies` is what the *server* believes is on this machine, which is
  the half of the exchange the harness cannot work out for itself — see
  `CmsHarness.WorkingCopyReporter`.

  Safe to call repeatedly, too, and `CmsHarness.WorkingCopyReporter` does. The
  observation it passes — `%{working_copy_id => present?}` — rides along on the
  same request, so re-announcing is how a removed worktree gets noticed and how
  a machine with no checkout on it proves it is alive at all.

  Identity is this module's job and observation is not, which is why that map is
  an argument rather than something computed here. Working out which checkouts
  are still on disk needs memory of the ones this harness has served: a copy
  whose directory is gone took its config file with it and can no longer name
  itself, so it simply stops appearing in `CmsHarness.WorkingCopies.all/0`.
  Computing the answer from that map alone would make a removed worktree
  *unreported* rather than reported missing — the one outcome the whole story
  exists to avoid. The memory lives in the reporter.

  ## This machine decides who it is, once

  The id presented is this machine's own — generated locally the first time
  there is none on file, never re-asked-for after. Confirmed live: more than
  one harness install can exist on a single box (a laptop running this
  checkout's own dev harness alongside a separately installed `cms start`
  serving other projects), and both used to treat `~/.codemyspec/device.json`
  as something the *server* was free to rewrite on every call. Two installs
  overwriting each other's belief of "who am I" is indistinguishable, from
  the server's side, from one machine that cannot hold an identity for more
  than a few seconds — every announce raced the last one, and the id a
  channel join read back the next moment was already stale. `write/1` now
  refuses to change an id already on file for exactly this reason: once
  established, it is a fact about the machine, not a question this module
  asks the server again.
  """

  @spec announce(%{optional(String.t()) => boolean()}) ::
          {:ok, %{device_id: String.t(), working_copies: %{String.t() => String.t()}}}
          | {:error, term()}
  def announce(observations \\ %{}) do
    # Written before the round trip, not after it. Minting and recording are
    # one act: the id is this machine's own, so there is nothing for a server
    # to confirm before it counts.
    #
    # Deferring the write until a reply arrived meant a machine that could not
    # reach the server held no id at all — it minted one on the line above,
    # sent it, failed, and dropped it. `ChannelClient` builds its join payload
    # from `recorded_id/0`, so the next join went out empty and the server
    # answered "This harness did not say which machine it is on", 0.2s after
    # that same daemon had announced. A network failure wearing an identity
    # failure's error message (3bc0f683).
    #
    # Worse on the fallback path. `fresh_id/0` prefers a hardware address and
    # recomputes the same value every time, but where there is none it falls
    # back to a random UUID — so with the server down, every announce minted a
    # different machine and kept none of them, and `WorkingCopyReporter` calls
    # this on a schedule rather than once at boot.
    id = ensure_id()

    with {:ok, token} <- credential(),
         {:ok, %{device_id: confirmed} = reply} <- post(id, token, observations) do
      write(confirmed || id)
      Logger.info("[CmsHarness] this machine is device #{confirmed || id}")
      {:ok, reply}
    else
      {:error, reason} = error ->
        Logger.warning(
          "[CmsHarness] could not announce this machine (#{inspect(reason)}); " <>
            "it is device #{id} and knows it, but will not appear in the device " <>
            "list until an announce reaches the server"
        )

        error
    end
  end

  # The id on file, minting and recording one if there is none.
  #
  # `write/1` is what makes this safe to call from several daemons at once: it
  # refuses to move an id already on file, so whichever process gets there
  # first decides and the rest read that answer back rather than replacing it.
  defp ensure_id do
    case recorded_id() do
      nil ->
        minted = fresh_id()
        write(minted)
        # Re-read rather than returning `minted`: another daemon on this box
        # may have written first, and its answer is the one that stands.
        recorded_id() || minted

      id ->
        id
    end
  end

  @doc "The identity this machine already holds, or nil."
  @spec recorded_id() :: String.t() | nil
  def recorded_id do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"device_id" => id}} when is_binary(id) and id != "" <- Jason.decode(body) do
      id
    else
      _ -> nil
    end
  end

  # Generated once, the first time this machine has no id at all. Preferred:
  # something the hardware itself already answers, so a wiped or lost
  # device.json still recomputes the same identity on the next boot instead
  # of looking like a new machine to the server. Falls back to a plain random
  # id wherever no such fingerprint is available (or the lookup fails) —
  # still generated locally, still asserted rather than asked for, just
  # without the self-healing property a hardware id would have added.
  defp fresh_id do
    machine_fingerprint() || Ecto.UUID.generate()
  end

  # `:inet.getifaddrs/0` rather than an OS-specific probe (macOS's `ioreg`,
  # Linux's `/etc/machine-id`, ...): it is part of OTP's own `:kernel`
  # application, answers identically on macOS, Linux and Windows, and needs
  # no shelled-out command or per-platform file path to fail differently on
  # each. A network interface's hardware address is burned into that
  # interface, not the OS install, so it survives a reinstall the same way
  # a firmware UUID would.
  #
  # Deliberately not "the interface getifaddrs happens to list first": that
  # order is not guaranteed stable across runs, so the lowest MAC among the
  # non-loopback, non-zero ones is picked instead — the same input always
  # sorts to the same answer.
  #
  # A MAC is 48 bits and `devices.id` is a UUID column, so the raw address
  # cannot be stored as-is — it is hashed into 16 bytes and loaded through
  # `Ecto.UUID.load/1` (the same function that turns a raw `binary_id` column
  # value into its dashed string form) purely to get UUID-shaped output.
  # Nothing here claims RFC 4122 version/variant correctness; Postgres's uuid
  # type and `Ecto.UUID.cast/1` both only check the string shape.
  defp machine_fingerprint do
    with {:ok, interfaces} <- :inet.getifaddrs(),
         mac when is_binary(mac) <- interfaces |> Enum.flat_map(&hwaddr/1) |> Enum.sort() |> List.first(),
         {:ok, uuid} <- mac |> then(&:crypto.hash(:md5, &1)) |> Ecto.UUID.load() do
      uuid
    else
      _ -> nil
    end
  end

  defp hwaddr({_name, opts}) do
    with false <- :loopback in Keyword.get(opts, :flags, []),
         [_ | _] = bytes <- Keyword.get(opts, :hwaddr, []),
         false <- Enum.all?(bytes, &(&1 == 0)) do
      [:binary.list_to_bin(bytes)]
    else
      _ -> []
    end
  end

  @doc """
  Where the identity is kept.

  Overridable so a test can point it somewhere disposable — the same seam
  `harness_secret_path` has, and for the same reason.
  """
  @spec path() :: String.t()
  def path do
    # `||` rather than `get_env/3`'s own default: that default only fires when
    # the key is *absent*, not when it is present and `nil` — which is exactly
    # what a test that restores this env var with `Application.get_env/2`'s own
    # bare, unset-means-nil result leaves behind. `Path.expand(nil)` raises,
    # and `recorded_id/0` is on `ChannelClient.handle_connect/1`'s hot path —
    # a background reconnect crashing on somebody else's test's leftover state
    # is a worse failure than this function being lenient about which "unset"
    # it was given.
    (Application.get_env(:code_my_spec, :device_config_path) || @default_path)
    |> Path.expand()
  end

  # What this machine is, from how it authenticates rather than from what it
  # calls itself. A sprite is pinned to one project and holds a deploy key; a
  # laptop has a signed-in user. That answer already exists at connect time and
  # was being discarded — a hostname was carrying it, badly, inside a free-text
  # label.
  defp kind do
    case Application.get_env(:code_my_spec, :project_id) do
      nil -> "local"
      _pinned -> "cloud"
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> nil
    end
  end

  defp credential do
    case Token.access_token() do
      {:ok, token} -> {:ok, token}
      _ -> Config.credential()
    end
  end

  # Through the seam rather than straight at `Req`. Writing this as a direct
  # call produced a spec that POSTed to the live server with a valid token
  # attached — an unpinned Req plus a credential is a live call, every time.
  defp post(device_id, token, observations) do
    Client.impl().announce(device_id, token, %{
      hostname: hostname(),
      kind: kind(),
      working_copies: observations
    })
  end

  # Merged over what is there rather than written fresh, so a field this version
  # does not know about survives a downgrade — the same rule `HarnessConfig.write/2`
  # follows for the per-checkout file.
  # Refuses to move an id already on file. This is what makes the identity
  # stable across two daemons on one box: whichever announced first settles
  # it, and neither this call nor a differently-answering server reply after
  # it can move the file again.
  defp write(id) do
    case recorded_id() do
      nil ->
        persist(id)

      ^id ->
        :ok

      other ->
        Logger.warning(
          "[CmsHarness] server confirmed device #{id} but this machine already " <>
            "holds #{other}; keeping #{other}"
        )

        :ok
    end
  end

  defp persist(id) do
    file = path()
    existing = if File.exists?(file), do: Jason.decode!(File.read!(file)), else: %{}
    body = existing |> Map.put("device_id", id) |> Jason.encode!(pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, body <> "\n") do
      # It sits beside a credential and names a machine; not world-readable.
      File.chmod(file, 0o600)
    end
  end
end
