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

  require Logger

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

    @doc "A proof counts only when a restore ran and found data."
    @spec verified?(t()) :: boolean()
    def verified?(%__MODULE__{rows: rows, proven_at: at}), do: rows > 0 and not is_nil(at)
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
         {:ok, key} <- take_dump(env, environment, opts),
         {:ok, proof} <- restore_proof(env, key, opts),
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
          {:ok, String.t()} | {:error, String.t()}
  def take_dump(env, environment, opts \\ []) do
    script = Keyword.get(opts, :backup_script, "bin/backup")

    case Environments.cmd(env, script, ["dump", environment], stderr_to_stdout: true) do
      {output, 0} ->
        case capture(output, "key") do
          nil -> {:error, "the backup script did not report the key it wrote: #{String.trim(to_string(output))}"}
          key -> {:ok, key}
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
    script = Keyword.get(opts, :backup_script, "bin/backup")
    target = Keyword.get(opts, :scratch_database, "scratch")

    case Environments.cmd(env, script, ["restore", key, target], stderr_to_stdout: true) do
      {output, 0} ->
        case rows(output) do
          n when n > 0 ->
            {:ok, %Proof{key: key, target: target, rows: n, proven_at: now.()}}

          _ ->
            {:error,
             "the dump restored into #{target} but the database came back empty — " <>
               "that is a file, not a backup"}
        end

      {output, status} ->
        {:error, "restoring #{key} into #{target} failed (exit #{status}): #{String.trim(to_string(output))}"}
    end
  end

  @doc """
  Install the nightly schedule on the server.

  Necessary, and deliberately not treated as evidence — see the moduledoc.
  """
  @spec install_schedule(Environments.Environment.t(), String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def install_schedule(env, environment, opts \\ []) do
    script = Keyword.get(opts, :backup_script, "bin/backup")

    case Environments.cmd(env, script, ["schedule", environment], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "installing the backup schedule failed (exit #{status}): #{String.trim(to_string(output))}"}
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
  defp rows(output), do: output |> capture("rows") |> to_integer()

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
end
