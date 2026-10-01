defmodule Mix.Tasks.Cms.DeviceOrphans do
  @shortdoc "List (and, with --commit, remove) devices no working copy sits on"

  @moduledoc """
  Issue 2dd9a959: one real laptop with thousands of `devices` rows.

      MIX_ENV=test mix cms.device_orphans

  Root cause (fixed separately, `CmsHarness.Device.machine_fingerprint/0`):
  every `Workspaces.Runner.Local`-booted workspace runs its own embedded
  harness, with its own `device.json` that never shares the laptop's real
  `~/.codemyspec` one by design (see `CmsHarness.Config.local_state_dir/0`).
  Each one minted its own id from whichever network interface happened to
  sort lowest, including several locally-administered, non-hardware
  addresses that come and go with whatever peripheral is paired — a
  different one most boots, so most boots announced as a brand-new machine.

  This cleans up what that already produced. "Orphan" means exactly one
  thing: zero `working_copies` reference the device, checked through
  `Devices.list_devices/1`'s own preload rather than a hostname guess — a
  device sharing a hostname with a real one is not evidence either way, only
  an empty `working_copies` list is. `destroy/2`'s own moduledoc says why
  that check has to be exact: a device *with* working copies attached
  cascades them away with it (migration `20260830120000`).

  Read-only by default — lists what it would remove, grouped by account.
  `--commit` backs up every row it is about to touch to a timestamped JSON
  file in the current directory, then removes each one through
  `CodeMySpec.Devices.destroy/2` (never a bulk query), reporting any it
  could not.

  Run under `MIX_ENV=test`: it points `CodeMySpec.Repo` at `code_my_spec_dev`
  but builds against test artifacts, the same reasoning `cms.provisioning_leaks`
  gives for the same seam — it never contends for the dev compile lock the
  running `:4000` server holds.
  """
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Devices
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @impl Mix.Task
  def run(args) do
    commit? = "--commit" in args

    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:code_my_spec)
    :ok = start_dev_repo()

    orphans_by_account = orphans_by_account()
    total = orphans_by_account |> Map.values() |> List.flatten() |> length()

    if total == 0 do
      Mix.shell().info("No orphaned devices found.")
    else
      report(orphans_by_account, total)

      if commit? do
        backup_path = backup!(orphans_by_account)
        Mix.shell().info("\nBacked up #{total} rows to #{backup_path}")
        destroy_all(orphans_by_account)
      else
        Mix.shell().info("\nRe-run with --commit to back up and remove these.")
      end
    end
  end

  # Mirrors `Mix.Tasks.Cms.ProvisioningLeaks.start_dev_repo/0` exactly — same
  # seam, same reasoning: a dynamically-named second connection so this never
  # fights the running dev server for its one configured repo name.
  defp start_dev_repo do
    config =
      :code_my_spec
      |> Application.get_env(Repo, [])
      |> Keyword.merge(
        name: :device_orphans_dev_repo,
        database: "code_my_spec_dev",
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    case Repo.start_link(config) do
      {:ok, _} -> Repo.put_dynamic_repo(:device_orphans_dev_repo)
      {:error, {:already_started, _}} -> Repo.put_dynamic_repo(:device_orphans_dev_repo)
    end

    :ok
  end

  # Every account that has a device at all, including the shared, accountless
  # case — `Devices.list_devices/1` itself answers `[]` for a scope with no
  # account, so there is nothing to sweep there and nothing to skip either.
  defp account_ids do
    Repo.all(
      from(d in "devices",
        where: not is_nil(d.account_id),
        distinct: true,
        select: type(d.account_id, :binary_id)
      )
    )
  end

  defp orphans_by_account do
    for account_id <- account_ids(),
        orphans = orphans_for(account_id),
        orphans != [],
        into: %{},
        do: {account_id, orphans}
  end

  defp orphans_for(account_id) do
    %Scope{active_account_id: account_id}
    |> Devices.list_devices()
    |> Enum.filter(&orphan?/1)
  end

  # Public and `@doc false`, the same seam `ProvisioningLeaks.leaked?/1` uses:
  # the one fact this whole task must get right, worth proving directly
  # against a device rather than only through a live query. Zero working
  # copies, not a hostname match — a device sharing a hostname with a real
  # one is not evidence either way.
  @doc false
  @spec orphan?(Devices.Device.t()) :: boolean()
  def orphan?(%Devices.Device{working_copies: copies}), do: copies == []

  defp report(orphans_by_account, total) do
    Mix.shell().info("#{total} orphaned device(s) across #{map_size(orphans_by_account)} account(s):\n")

    for {account_id, devices} <- orphans_by_account do
      Mix.shell().info("  account #{account_id} (#{length(devices)}):")

      devices
      |> Enum.group_by(& &1.hostname)
      |> Enum.each(fn {hostname, group} ->
        Mix.shell().info("    #{inspect(hostname)}: #{length(group)}")
      end)
    end
  end

  defp backup!(orphans_by_account) do
    path = "device_orphans_backup_#{timestamp()}.json"

    rows =
      for {account_id, devices} <- orphans_by_account,
          device <- devices do
        %{
          id: device.id,
          hostname: device.hostname,
          label: device.label,
          kind: device.kind,
          account_id: account_id,
          last_seen_at: device.last_seen_at,
          inserted_at: device.inserted_at,
          updated_at: device.updated_at
        }
      end

    File.write!(path, Jason.encode!(rows, pretty: true) <> "\n")
    path
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")

  defp destroy_all(orphans_by_account) do
    for {account_id, devices} <- orphans_by_account do
      scope = %Scope{active_account_id: account_id}

      for device <- devices do
        case Devices.destroy(scope, device) do
          {:ok, _} -> Mix.shell().info("    removed #{device.id} (#{device.hostname})")
          {:error, reason} -> Mix.shell().error("    FAILED  #{device.id}: #{inspect(reason)}")
        end
      end
    end
  end
end
