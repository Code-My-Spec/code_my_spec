defmodule CodeMySpec.Provisioning.Backups do
  @moduledoc """
  Nightly dumps into Sam's own bucket, and the restore that proves they are
  backups rather than files.

  ## A file is not a backup until it has restored

  Story 968's gate criterion (8054) is the whole design here: setup does not
  call this step done until it has taken a dump, restored it into a throwaway
  database, and counted rows. Checking that an object landed with a plausible
  size is a guess, and the guess is wrong on exactly the day it matters —
  a dump of an empty database, a truncated upload, and a good backup all look
  the same from the object listing.

  So `run/3` sequences retention → dump → restore-proof → schedule, and the
  proof carries its own timestamp so `proven_at <= done_at` is checkable
  rather than asserted.

  ## The schedule is installed, but the schedule is not the evidence

  `install_schedule/3` writes a systemd timer on the server. Criterion 8014 is
  careful to assert on the artifact in the bucket rather than the presence of
  a timer, because a timer that fires into a broken script produces nothing
  and reports nothing. Installing it is necessary; it is not proof.

  ## The dump never passes through us

  `bin/backup dump` uploads straight from the server to Sam's bucket and
  prints the key it wrote; `bin/backup restore` pulls that key back down. A
  database dump is exactly the kind of thing that is small in a test and tens
  of gigabytes in production, and routing it through the control plane would
  make setup's memory a function of Sam's data size. It also keeps his data on
  his own two machines, which is the same argument story 968 makes about the
  bucket.

  So this module orchestrates and reads results; it never holds a dump.

  ## Silence is the failure mode worth designing against

  `health/2` reports `:stalled` when the newest dump is older than the window
  a schedule should have produced one in. A backup that quietly stops is worse
  than no backup at all: it removes the pressure to check, so the gap is only
  discovered by someone who needed to restore (criterion 8015).
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Storage

  @default_retention_days 14

  # A nightly schedule that has produced nothing in two days has stopped, and
  # one late run should not cry wolf.
  @stale_after_hours 48

  defmodule Proof do
    @moduledoc """
    What a restore actually demonstrated.

    Deliberately has no boolean `ok` field independent of `rows`: the only
    evidence a dump is restorable is that it restored and the data was there,
    so `verified?` is derived rather than set.
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

    `proven_at` is set only by the path that restored the dump *and* found what
    went into it — `restore_proof/3` compares the restored count with the source
    count and returns an error otherwise. So the timestamp is the evidence, and
    `rows > 0` alongside it was not a second check but a wrong one: a freshly
    provisioned database has migrations and no rows, and a correct backup of it
    restores zero. Requiring more than zero called that a file rather than a
    backup.
    """
    @spec verified?(t()) :: boolean()
    def verified?(%__MODULE__{proven_at: at}), do: not is_nil(at)
  end

  @doc """
  Take a dump, upload it, and prove it restores.

  Returns `{:ok, %{key: key, proof: proof}}` only when the restore succeeded —
  see the moduledoc for why the upload alone is not enough.
  """
  @spec run(Environments.Environment.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(env, environment, opts) do
    with {:ok, bucket} <- fetch(opts, :bucket),
         {:ok, credentials} <- fetch(opts, :credentials),
         # Retention first: the rule has to be in force before the first dump
         # lands, or that dump is the one object nothing ever expires.
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

  The script names the key, because the script is what writes it; taking its
  word for a key it did not write is how a listing and a restore end up
  disagreeing. The key carries the environment and a timestamp so a listing
  reads as a history — criterion 8014 asserts a dump is *dated from that run*,
  which an opaque name cannot answer.
  """
  @spec take_dump(Environments.Environment.t(), String.t(), keyword()) ::
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
            # The source count travels with the key, so the restore is compared
            # with what went in rather than with zero. `nil` when the script is
            # an older one that does not print it.
            {:ok, key, rows_or_nil(output)}
        end

      {output, status} ->
        {:error, "pg_dump failed (exit #{status}): #{String.trim(to_string(output))}"}
    end
  end

  @doc """
  Restore a dump into a throwaway database and count what came back.

  The scratch database is the point: restoring into the live one would be a
  destructive test, and restoring into nothing at all proves nothing. Criterion
  8017 asks for a restore that completes *and* data that is present, so both
  are checked and `rows` is carried rather than a bare boolean.
  """
  @spec restore_proof(Environments.Environment.t(), String.t(), keyword()) ::
          {:ok, Proof.t()} | {:error, String.t()}
  def restore_proof(env, key, opts \\ []) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    script = resolve_script(env, Keyword.get(opts, :backup_script, "bin/backup"))
    target = Keyword.get(opts, :scratch_database, "scratch")

    # Against what went in, not against zero.
    #
    # `> 0` cannot tell a broken backup from a legitimately empty database, and
    # that is the whole distinction this check exists to draw. A freshly
    # provisioned application has migrations and no rows, so its first backup is
    # correct and reported "that is a file, not a backup" — which is how a cold
    # rebuild failed on a dump that was fine.
    #
    # `expected` is the source count, printed by `dump`. Equal means everything
    # that was there came back, including when nothing was there. An older
    # script that does not print it falls back to the previous rule, so a
    # project whose `bin/backup` predates this is no worse off than before.
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

  Necessary, and deliberately not treated as evidence — see the moduledoc.
  """
  @spec install_schedule(Environments.Environment.t(), String.t(), keyword()) ::
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
  into "not healthy", because "it stopped last Tuesday" and "it never ran"
  send Sam to different places.
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

  # The scripts report `name=value` on stdout. One line-oriented convention
  # keeps the contract between here and the server small enough to hold in
  # your head, and greppable from a shell when a run goes wrong.
  # Equal to what went in is the proof, whatever that number is — zero included,
  # for a database that genuinely has no rows yet.
  defp restore_verdict(restored, expected) when is_integer(expected) and restored == expected,
    do: :ok

  defp restore_verdict(_restored, expected) when is_integer(expected),
    do: {:short, expected}

  # No source count: an older `bin/backup` that does not print one. Keep the
  # rule it was written against rather than inventing a verdict from nothing.
  defp restore_verdict(restored, _expected) when restored > 0, do: :ok
  defp restore_verdict(_restored, _expected), do: :empty

  defp rows(output), do: output |> capture("rows") |> to_integer()

  # Absent rather than zero when the script did not print it: zero is a real
  # answer for an empty database, so it must not double as "unknown".
  defp rows_or_nil(output) do
    case capture(output, "rows") do
      nil -> nil
      value -> to_integer(value)
    end
  end

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

  # Relative to the *project*, not to whatever directory the caller happens to
  # be in. `System.cmd/3` resolves a relative command against the running
  # process's cwd, not the environment's, so `bin/backup` was looked for beside
  # the server rather than beside the project and failed with :enoent — an
  # error that names nothing and reads like the script was never generated.
  # The step has already resolved the bucket and the object-storage keys to get
  # this far, so it hands them to the script rather than leaving it to find them
  # again — the script's own sops fallback is for a human running it by hand,
  # not for the path where the caller knows the answer. `DATABASE_URL` is passed
  # only when a caller supplies one; otherwise the script sources it from the
  # app's encrypted env file, which is where it lives on a real box.
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
      # The script decrypts the environment file itself — `source <(sops -d
      # …)` — and sops takes its identity from this variable and nowhere else.
      # Without it the dump failed with "no identity matched any of the
      # recipients", which reads like a key problem rather than a missing
      # variable.
      #
      # Passing the key rather than the decrypted value keeps the script
      # self-contained, which is what it has to be: it also runs from cron on
      # the server, with nobody to hand it a connection string.
      {"SOPS_AGE_KEY", Keyword.get(opts, :age_key)}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end


  # Where the script runs, which is not where the caller runs.
  #
  # All three of these shelled out through `Environments.cmd/4` — the *project's
  # local* environment, meaning the machine running setup. Three things follow,
  # and the third is the serious one:
  #
  #   * the dump cannot reach the database. `DATABASE_URL` names `cms-postgres`,
  #     a container on the server's private docker network, so a local `pg_dump`
  #     reports `could not translate host name "cms-postgres" to address`;
  #   * it contradicts this script's own header, which says the dump goes
  #     straight from the host to the bucket and never through the control plane
  #     — a production dump being exactly the thing that is a megabyte in
  #     staging and eighty gigabytes in production;
  #   * `schedule` runs `sudo tee /etc/systemd/system/...` and
  #     `systemctl enable --now`. Run locally that installs a nightly timer on
  #     whatever machine ran setup — a laptop in development — pointed at a
  #     database it cannot reach. It fails on a host without passwordless sudo
  #     and *succeeds* on one with it, which is the worse outcome.
  #
  # `:run` takes `[command]` and returns `{output, status}`, the same shape
  # `Registry` and `Database` already use, so the caller decides which box this
  # happens on and the tests keep a local path that needs no server.
  defp run_script(env, script, args, opts) do
    case Keyword.get(opts, :run) do
      nil ->
        Environments.cmd(env, script, args, stderr_to_stdout: true, env: script_env(opts))

      run ->
        # The *relative* name, not the resolved one. `resolve_script/2` makes it
        # absolute against the project's local checkout, which is a path that
        # exists on this machine and nowhere else.
        run.([remote_command(Keyword.get(opts, :backup_script, "bin/backup"), args, opts)])
    end
  end

  # One shell line: cd to the delivered tree, export what the script reads, run
  # it. The environment cannot travel as `System.cmd`'s `:env` over ssh, so it
  # is spelled out in the command — quoted, because a secret access key is not
  # guaranteed to be shell-safe.
  defp remote_command(script, args, opts) do
    exports =
      opts
      |> script_env()
      |> Enum.map_join(" ", fn {name, value} -> "#{name}=#{shell_quote(value)}" end)

    dir = Keyword.get(opts, :remote_dir, ".")

    "cd #{shell_quote(dir)} && #{exports} #{script} #{Enum.map_join(args, " ", &shell_quote/1)}"
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  defp resolve_script(%{cwd: cwd}, script) when is_binary(cwd) and cwd != "" do
    if Path.type(script) == :absolute, do: script, else: Path.join(cwd, script)
  end

  defp resolve_script(_env, script), do: script
end
