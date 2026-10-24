defmodule CodeMySpec.Provisioning.Backups do
  @moduledoc """
  Nightly dumps into the user's own bucket, and the restore that proves they
  are backups rather than files.

  `run/3` sequences retention → dump → restore-proof → schedule, and is done
  only once a dump has been restored into a scratch database with every source
  row present. The installed timer is necessary but not evidence. Dumps go
  straight from the server to the bucket and never pass through this process.
  `health/2` reports `:stalled` when the newest dump is older than the window.

  See knowledge/provisioning, "Backups".
  """

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Provisioning.Storage

  @default_retention_days 14

  # A nightly schedule that has produced nothing in two days has stopped, and
  # one late run should not cry wolf.
  @stale_after_hours 48

  defmodule Proof do
    @moduledoc """
    What a restore actually demonstrated.

    `verified?` is derived from `proven_at`, not set as a separate flag.
    """

    @type t :: %__MODULE__{
            key: String.t() | nil,
            target: String.t(),
            rows: non_neg_integer(),
            proven_at: DateTime.t() | nil,
            reason: String.t() | nil
          }

    defstruct key: nil, target: "scratch", rows: 0, proven_at: nil, reason: nil

    @doc """
    A proof counts when a restore actually ran.

    `proven_at` is set only by `restore_proof/3` when the restored count
    matches the source count, so the timestamp is the evidence. Zero rows can
    be a correct backup of a freshly migrated database.
    """
    @spec verified?(t()) :: boolean()
    def verified?(%__MODULE__{proven_at: at}), do: not is_nil(at)
  end

  @doc """
  Take a dump, upload it, and prove it restores.

  Returns `{:ok, %{key: key, proof: proof, ...}}` only when the restore
  succeeded.
  """
  @spec run(ExecutionContexts.ExecutionContext.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(env, environment, opts) do
    with {:ok, bucket} <- fetch(opts, :bucket),
         {:ok, credentials} <- fetch(opts, :credentials),
         # Retention first, or the first dump is the one object nothing expires.
         :ok <- Storage.put_lifecycle(bucket, retention_days(opts), credentials, opts),
         {:ok, key, source_rows} <- take_dump(env, environment, opts),
         {:ok, proof} <-
           restore_proof(env, key, Keyword.put(opts, :expected_rows, source_rows)),
         :ok <- install_schedule(env, environment, opts) do
      {:ok, %{key: key, proof: proof, bucket: bucket, retention_days: retention_days(opts)}}
    end
  end

  @doc """
  Dump the environment's database to the bucket and return the key it landed
  under.

  The script names the key, because the script is what writes it. The key
  carries the environment and a timestamp so a listing reads as a history.
  """
  @spec take_dump(ExecutionContexts.ExecutionContext.t(), String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer() | nil} | {:error, String.t()}
  def take_dump(env, environment, opts \\ []) do
    script = resolve_script(env, Keyword.get(opts, :backup_script, "bin/backup"))

    case run_script(env, script, ["dump", environment], opts) do
      {output, 0} ->
        case capture(output, "key") do
          nil ->
            {:error,
             "the backup script did not report the key it wrote: #{String.trim(to_string(output))}"}

          key ->
            # The source count travels with the key so the restore is compared
            # with what went in. `nil` when an older script does not print it.
            {:ok, key, rows_or_nil(output)}
        end

      {output, status} ->
        {:error, "pg_dump failed (exit #{status}): #{String.trim(to_string(output))}"}
    end
  end

  @doc """
  Restore a dump into a throwaway database and count what came back.

  Restoring into the live database would be a destructive test, so the
  restore targets a scratch database and carries `rows`.
  """
  @spec restore_proof(ExecutionContexts.ExecutionContext.t(), String.t(), keyword()) ::
          {:ok, Proof.t()} | {:error, String.t()}
  def restore_proof(env, key, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    script = resolve_script(env, Keyword.get(opts, :backup_script, "bin/backup"))
    target = Keyword.get(opts, :scratch_database, "scratch")

    # Compared against the source count printed by `dump`, not against zero:
    # an empty database's correct backup restores zero rows.
    expected = Keyword.get(opts, :expected_rows)

    case run_script(env, script, ["restore", key, target], opts) do
      {output, 0} ->
        restored = rows(output)

        case restore_verdict(restored, expected) do
          :ok ->
            {:ok, %Proof{key: key, target: target, rows: restored, proven_at: now.()}}

          {:short, missing} ->
            {:error,
             "the dump restored into #{target} with #{restored} row(s), but #{missing} " <>
               "went in — a restore that loses data is not a backup"}

          :empty ->
            {:error,
             "the dump restored into #{target} but the database came back empty — " <>
               "that is a file, not a backup"}
        end

      {output, status} ->
        {:error,
         "restoring #{key} into #{target} failed (exit #{status}): #{String.trim(to_string(output))}"}
    end
  end

  @doc """
  Install the nightly schedule on the server.

  Necessary, but not treated as evidence.
  """
  @spec install_schedule(ExecutionContexts.ExecutionContext.t(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def install_schedule(env, environment, opts \\ []) do
    script = resolve_script(env, Keyword.get(opts, :backup_script, "bin/backup"))

    case run_script(env, script, ["schedule", environment], opts) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error,
         "installing the backup schedule failed (exit #{status}): #{String.trim(to_string(output))}"}
    end
  end

  @doc """
  Whether backups are still arriving.

  `:stalled` when the newest dump is older than the staleness window, and
  `:never` when there are none at all. Both are reported rather than folded
  into "not healthy", because "it stopped" and "it never ran" need different
  fixes.
  """
  @spec health([map()], keyword()) :: map()
  def health(dumps, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0).()
    window = Keyword.get(opts, :stale_after_hours, @stale_after_hours)

    case newest(dumps) do
      nil ->
        %{state: "never", last_seen: nil, stale_after_hours: window}

      %{taken_at: taken_at} = dump ->
        state = if hours_since(taken_at, now) > window, do: "stalled", else: "healthy"
        %{state: state, last_seen: dump.taken_at, stale_after_hours: window}
    end
  end

  @doc "How long dumps are kept, in days."
  @spec retention_days(keyword()) :: pos_integer()
  def retention_days(opts), do: Keyword.get(opts, :retention_days, @default_retention_days)

  ## Internals

  defp fetch(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, "the backups step needs #{key} — storage must run first"}
      value -> {:ok, value}
    end
  end

  defp newest([]), do: nil
  defp newest(dumps), do: Enum.max_by(dumps, & &1.taken_at, fn -> nil end)

  # Equal to what went in is the proof, zero included.
  defp restore_verdict(restored, expected) when is_integer(expected) and restored == expected,
    do: :ok

  defp restore_verdict(_restored, expected) when is_integer(expected),
    do: {:short, expected}

  # No source count (an older `bin/backup`): fall back to `> 0`.
  defp restore_verdict(restored, _expected) when restored > 0, do: :ok
  defp restore_verdict(_restored, _expected), do: :empty

  defp rows(output), do: output |> capture("rows") |> to_integer()

  # Absent rather than zero when not printed: zero is a real answer.
  defp rows_or_nil(output) do
    case capture(output, "rows") do
      nil -> nil
      value -> to_integer(value)
    end
  end

  # The scripts report `name=value` lines on stdout.
  defp capture(output, name) do
    case Regex.run(~r/^#{name}=(\S+)$/m, to_string(output)) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp to_integer(nil), do: 0

  defp to_integer(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp hours_since(taken_at, now) do
    case DateTime.from_iso8601(to_string(taken_at)) do
      {:ok, at, _} -> DateTime.diff(now, at, :second) / 3600
      _ -> :infinity
    end
  end

  # The step already knows the bucket, keys and age key, so it hands them over;
  # the script's own sops fallback is for a human running it by hand.
  # `DATABASE_URL` is passed only when supplied; otherwise the script sources it
  # from the app's encrypted env file.
  defp script_env(opts) do
    credentials = Keyword.get(opts, :credentials, [])
    location = Keyword.get(credentials, :region, "nbg1")

    [
      {"BACKUP_BUCKET", Keyword.get(opts, :bucket)},
      {"BACKUP_ENDPOINT", "https://#{location}.your-objectstorage.com"},
      {"AWS_ACCESS_KEY_ID", Keyword.get(credentials, :access_key_id)},
      {"AWS_SECRET_ACCESS_KEY", Keyword.get(credentials, :secret_access_key)},
      {"AWS_REGION", location},
      {"DATABASE_URL", Keyword.get(opts, :database_url)},
      # `bin/backup restore`'s own credential for its scratch database — never
      # the app's (see `Database`).
      {"CMS_RESTORE_ADMIN_URL", Keyword.get(opts, :restore_admin_url)},
      # sops takes its identity only from this variable; the script also runs
      # from cron, so it decrypts for itself.
      {"SOPS_AGE_KEY", Keyword.get(opts, :age_key)}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  # Where the script runs, which is not where the caller runs: `:run` executes
  # on the server (it takes `[command]`, returns `{output, status}`, like
  # `Registry` and `Database`). Without it, `ExecutionContexts.cmd/4` runs locally,
  # for tests. See knowledge/provisioning, "Backups".
  defp run_script(env, script, args, opts) do
    case Keyword.get(opts, :run) do
      nil ->
        ExecutionContexts.cmd(env, script, args, stderr_to_stdout: true, env: script_env(opts))

      run ->
        # The relative name: `resolve_script/2`'s path exists only locally.
        run.([remote_command(Keyword.get(opts, :backup_script, "bin/backup"), args, opts)])
    end
  end

  # One shell line: cd to the delivered tree, export what the script reads, run
  # it. Env cannot travel as `:env` over ssh, so it is spelled out, quoted.
  defp remote_command(script, args, opts) do
    exports =
      opts
      |> script_env()
      |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{shell_quote(value)}" end)

    dir = Keyword.get(opts, :remote_dir, ".")

    "cd #{shell_quote(dir)} && #{exports} #{script} #{Enum.map_join(args, " ", &shell_quote/1)}"
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  # Relative to the project checkout: `System.cmd/3` resolves a relative
  # command against the process's cwd.
  defp resolve_script(%{cwd: cwd}, script) when is_binary(cwd) and cwd != "" do
    if Path.type(script) == :absolute, do: script, else: Path.join(cwd, script)
  end

  defp resolve_script(_env, script), do: script
end
