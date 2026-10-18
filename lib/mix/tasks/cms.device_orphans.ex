defmodule Mix.Tasks.Cms.DeviceOrphans do
  @shortdoc "List or back up and remove devices with no working copies"
  @moduledoc """
  Uses CodeMySpec.Repo's configured database in the selected MIX_ENV.
  Never substitutes a development database. Read-only unless --commit is given.

      mix cms.device_orphans --account ACCOUNT_UUID
      mix cms.device_orphans --account ACCOUNT_UUID --commit --backup backup.json

  Without --account, scans all account-owned devices. Accountless devices are
  left alone. A commit requires a new backup file; existing files are never
  overwritten. Backups contain every device field, including tunnel credentials,
  and are written with owner-only permissions. Keep them secure.

  Device rows are locked before checking working-copy references, preventing a
  concurrent attachment from being cascaded away by cleanup. A failed backup
  aborts deletion. cleanup/3 accepts a repo and scope for sandboxed tests.
  """
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  import Ecto.Query

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [commit: :boolean, account: :string, backup: :string])

    if rest != [] or invalid != [], do: Mix.raise("Invalid cleanup arguments")
    scope = account_scope(Keyword.get(opts, :account))
    Mix.Task.run("app.config")
    config = configured_repo!(Repo.config())
    Mix.Task.run("app.start")

    # Preserve the configured destination; only the connection pool is changed
    # so a command-line invocation does not require an ExUnit sandbox owner.
    {:ok, pid} =
      Repo.start_link(
        Keyword.merge(config, name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)
      )

    previous = Repo.get_dynamic_repo()

    try do
      Repo.put_dynamic_repo(pid)
      result = cleanup(Repo, scope, opts)
      report(result)
    after
      Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end

  @doc false
  def configured_repo!(config) do
    case Keyword.get(config, :database) do
      database when is_binary(database) and byte_size(database) > 0 -> config
      _ -> raise ArgumentError, "Cleanup requires an explicitly configured database"
    end
  end

  defp account_scope(nil), do: :all

  defp account_scope(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> %Scope{active_account_id: id}
      :error -> Mix.raise("--account must be an account UUID")
    end
  end

  @doc "List or remove orphan devices in a supplied repo and account scope."
  def cleanup(repo, scope, opts \\ []) do
    query = scoped_devices(scope)

    if Keyword.get(opts, :commit, false) do
      path = Keyword.fetch!(opts, :backup)

      repo.transaction(fn ->
        devices = repo.all(from d in query, order_by: d.id, lock: "FOR UPDATE")
        orphans = without_copies(repo, devices)
        remove_backed_up(repo, orphans, path)
      end)
    else
      devices = repo.all(query) |> then(&without_copies(repo, &1))
      {:ok, %{devices: devices, removed: 0, backup: nil}}
    end
  end

  defp scoped_devices(:all), do: from(d in Device, where: not is_nil(d.account_id))

  defp scoped_devices(%Scope{active_account_id: id}) when is_binary(id),
    do: from(d in Device, where: d.account_id == ^id)

  defp without_copies(repo, devices) do
    ids = Enum.map(devices, & &1.id)

    attached =
      repo.all(from w in WorkingCopy, where: w.device_id in ^ids, select: w.device_id)
      |> MapSet.new()

    Enum.reject(devices, &MapSet.member?(attached, &1.id))
  end

  defp remove_backed_up(_repo, [], _path), do: %{devices: [], removed: 0, backup: nil}

  defp remove_backed_up(repo, devices, path) do
    rows = Enum.map(devices, &Map.take(&1, Device.__schema__(:fields)))
    backup!(path, Jason.encode!(rows, pretty: true) <> "\n")
    Enum.each(devices, &repo.delete!/1)
    %{devices: devices, removed: length(devices), backup: path}
  end

  defp backup!(path, content) do
    file = File.open!(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(file, content)
      :ok = :file.sync(file)
    after
      :ok = File.close(file)
    end
  end

  @doc false
  def orphan?(copy_ids) when is_list(copy_ids), do: copy_ids == []

  defp report({:ok, %{devices: devices, removed: removed, backup: backup}}) do
    Mix.shell().info("#{length(devices)} orphaned device(s); #{removed} removed")
    if backup, do: Mix.shell().info("Backup: #{backup}")
  end

  defp report({:error, reason}), do: Mix.raise("Cleanup failed: #{inspect(reason)}")
end
