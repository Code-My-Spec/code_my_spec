defmodule CodeMySpecSpex.Fakes.Shell do
  @moduledoc """
  A shell whose commands have effects, not just output.

  The fifth fake, and the one the others cannot substitute for. A cassette
  records what a command *printed*; provisioning depends on what it *did*.
  `ssh-keygen -f path` writes a key, `sops encrypt --in-place f` rewrites `f`,
  `git archive | ssh tar -x` puts a tree on a box. On replay the stdout comes
  back and none of that happens, so the next step reads a world the recording
  never left behind — which is exactly why 963/7965 records green and replays
  red, its second run asking for an `ssh-keygen` the first run's recording had
  no reason to contain.

  Writes into the environment's own in-memory filesystem, so the effect is
  there for the next command to find. That is the whole idea: the memfs was
  already the virtual filesystem, and this connects the shell to it.

  ## Fidelity

  Commands are modelled where their effect matters and refused where it does
  not exist. An unmodelled command answers non-zero, naming itself — a shell
  that silently succeeds at everything makes every step pass and proves
  nothing, which is worse than the cassettes.

  ## What stays real

  Anything whose *outcome* is the claim: a box answering over HTTPS, an image
  running on an architecture, a dump restoring. Those belong to the drill. This
  models the mechanics that get you there.
  """

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fakes.Storage

  # What `dump` says went in and `restore` says came back. One number, because
  # the step compares them and a mismatch is reported as data loss.
  @backup_rows 42

  @doc "Run a command against the environment's filesystem."
  def cmd(env, command, args, opts) do
    run(env, command, args, opts)
  end

  # -- ssh-keygen: the command whose effect broke replay --

  defp run(env, "ssh-keygen", args, _opts) do
    case key_path(args) do
      nil ->
        # `-R host` removes a known-hosts entry. No effect worth modelling, and
        # the step ignores the result.
        {"", 0}

      path ->
        Environments.write_file(env, path, "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n")
        Environments.write_file(env, path <> ".pub", "ssh-ed25519 AAAAC3Nz#{hash(path)} spex")

        {"Your identification has been saved in #{path}\n", 0}
    end
  end

  # -- age: one key pair per environment, printed --

  defp run(_env, "age-keygen", _args, _opts) do
    public = "age1#{hash("age")}"

    {"# created: 2026-01-01T00:00:00Z\n# public key: #{public}\nAGE-SECRET-KEY-1#{hash("sec")}\n",
     0}
  end

  # -- sops: a file that round-trips. `set` puts a key in, `decrypt` reads the
  # keys back out, and `encrypt` stamps the recipient from `.sops.yaml` so
  # `recipients/2` — which regex-scans the ciphertext for `age1…` — finds one.
  #
  # Round-tripping is the whole point rather than an extra. The deploy step
  # asks `missing_secrets/4` what the environment carries, and a `sops` that
  # exits 0 while printing nothing answers "everything is missing" — which is
  # how a fully provisioned run reported "prod is missing SECRET_KEY_BASE,
  # DATABASE_URL" and stopped one step short of the thing it was proving.
  #
  # Plaintext dotenv on both sides of the door, because what is being modelled
  # is that a secret written can be read back with the right key, and nothing
  # in provisioning reads the ciphertext's shape. It still refuses on a file
  # that is not there — the failure 7965 surfaced when the secrets step had not
  # run.

  defp run(env, "sops", args, _opts) do
    case sops_target(args) do
      nil ->
        {"", 0}

      path ->
        case Environments.read_file(env, path) do
          {:ok, contents} ->
            sops_command(env, args, path, contents)

          _ ->
            # What is there, not only what is missing. A path that does not
            # exist has two causes — nobody wrote it, or it was written
            # somewhere else — and the message naming only the absent one sends
            # the reader to the wrong half.
            {"Error: cannot operate on non-existent file #{inspect(path)}\n" <>
               "The environment holds: #{inspect(listing(env))}\n", 128}
        end
    end
  end

  # -- git: the ones the steps use --

  defp run(_env, "git", ["rev-parse" | _], _opts), do: {"#{hash("HEAD")}\n", 0}
  defp run(_env, "git", ["archive" | _], _opts), do: {"", 0}

  # A remote that has moved on refuses the push, and the step is not done until
  # one lands — criterion 8184 is exactly that distinction, and a repository
  # that exists is not the same claim as a push that succeeded. Injected rather
  # than inferred: nothing on this side knows what the remote holds, and a fake
  # that guessed would be deciding the criterion rather than serving it.
  defp run(_env, "git", ["push" | _] = args, _opts) do
    case Application.get_env(:code_my_spec, :memory_shell_push) do
      :rejected ->
        {" ! [rejected]        main -> main (non-fast-forward)\n" <>
           "error: failed to push some refs\n" <>
           "hint: Updates were rejected because the tip of your current branch is behind\n", 1}

      _ ->
        {"To github.com\n * [new branch]      #{Enum.join(args, " ")}\n", 0}
    end
  end

  defp run(_env, "git", _args, _opts), do: {"", 0}

  # -- ssh: a box that answers. What it answers *about* is the drill's --

  defp run(_env, "ssh", args, _opts), do: {remote_answer(Enum.join(args, " ")), 0}
  defp run(_env, "scp", _args, _opts), do: {"", 0}

  # `sh -c "git archive … | ssh … tar -x"` is how a tree reaches a box. The
  # pipeline's effect is on the far side, which nothing here reads.
  defp run(_env, "sh", ["-c" | _], _opts), do: {"", 0}

  # -- mix: the generators the steps run, which are generators because their
  # effect is a file --

  defp run(env, "mix", ["cms_gen.support_widget" | _], _opts) do
    # `installed?/2` looks for `lib/<app>_web/live/support_widget_live.ex` and
    # skips the generator when it is already there, so writing it is both the
    # effect and what makes a second run a no-op rather than a re-generation.
    for entry <- web_dirs(env) do
      Environments.write_file(
        env,
        "lib/#{entry}/live/support_widget_live.ex",
        "defmodule SupportWidgetLive do\n  # data-cms-widget\nend\n"
      )
    end

    {"* creating lib/app_web/live/support_widget_live.ex\n", 0}
  end

  defp web_dirs(env) do
    case Environments.list_directory(env, "lib") do
      {:ok, entries} -> Enum.filter(entries, &String.ends_with?(&1, "_web"))
      _ -> []
    end
  end

  # -- the generated scripts, run by absolute path out of the checkout --
  #
  # `bin/deploy <command> <environment>` is what the deploy step shells out to,
  # and what its failure text quotes back — so what matters is the exit status
  # and that the environment named reaches the answer. The work it stands for
  # (kamal pushing an image, running a migration, swapping traffic) happens on
  # a box, and nothing on this side reads it.
  defp run(_env, command, args, opts) do
    case Path.basename(command) do
      "deploy" ->
        {"deployed #{Enum.join(args, " ")}\n", 0}

      # Run from here the script is handed its environment through `:env`
      # rather than through shell exports, so the bucket comes from there.
      "backup" ->
        backup(args, opts |> Keyword.get(:env, []) |> Enum.into(%{}) |> Map.get("BACKUP_BUCKET"))

      "migrate" ->
        {"migrated\n", 0}

      _ ->
        unmodelled(command, args)
    end
  end

  # `bin/backup` reports what it did in `key=…` / `rows=…` lines, and the step
  # takes the script's word for the key because the script is what wrote it.
  #
  # The two subcommands have to agree: `restore` is checked against the count
  # `dump` printed, and a restore that comes back short is reported as "a
  # restore that loses data is not a backup". A fake answering a different
  # number each time would produce exactly that failure, about nothing.
  defp backup(args, bucket), do: args |> Enum.map(&unquote_arg/1) |> backup_command(bucket)

  # A dump that lands somewhere. `bin/backup dump` pg_dumps and uploads to the
  # bucket, and the listing that criterion 8014 reads is an ordinary
  # `ListObjects` against that bucket — so a fake that only prints a key
  # produces a report of "no dumps" after a run that reported success, which is
  # the exact failure 968 exists to catch and would be reporting falsely.
  #
  # The bucket travels in the command as `BACKUP_BUCKET`, the same way the real
  # script learns it, and the object goes into the storage fake if one is
  # wired. No storage fake means no upload rather than an error: not every
  # criterion running a backup cares where it landed.
  defp backup_command(["dump", environment | _], bucket) do
    key = dump_key(environment)
    put_object(bucket, key)

    {"key=#{key}\nrows=#{@backup_rows}\n", 0}
  end

  defp backup_command(["restore" | _], _bucket), do: {"rows=#{@backup_rows}\n", 0}
  defp backup_command(["install_schedule" | _], _bucket), do: {"installed\n", 0}
  defp backup_command(_args, _bucket), do: {"", 0}

  # `cd /opt/… && BACKUP_BUCKET='b' AWS_… bin/backup dump 'uat'` — the exports
  # come *before* the script name, so reading them off the arguments found
  # nothing and every remote dump uploaded into a bucket called nil.
  defp bucket_from(command) do
    case Regex.run(~r/BACKUP_BUCKET='?([^'\s]+)'?/, command) do
      [_, bucket] -> bucket
      _ -> nil
    end
  end

  defp put_object(nil, _key), do: :ok

  defp put_object(bucket, key) do
    case Application.get_env(:code_my_spec, :memory_shell_storage) do
      nil -> :ok
      agent -> Storage.put_object(agent, bucket, key, "-- pg_dump --\n")
    end
  end

  # Over ssh the arguments arrive shell-quoted — `remote_command/3` wraps every
  # one in single quotes because a secret access key is not guaranteed to be
  # shell-safe. A real shell strips them before the script sees them; matching
  # on `"'dump'"` instead of `"dump"` is how this fake answered nothing to a
  # dump it had a perfectly good answer for.
  defp unquote_arg(arg) do
    case String.starts_with?(arg, "'") and String.ends_with?(arg, "'") do
      true -> String.slice(arg, 1..-2//1)
      false -> arg
    end
  end

  # The key the generated script really writes: `dumps/<environment>/<app>-
  # <stamp>.sql.gz`. Under `dumps/` because that is the prefix the app lists to
  # answer "are backups still arriving?" — the script says so in its own
  # comment, and a dump written anywhere else is invisible to the listing,
  # which is how this fake first reported no dumps after a run that had just
  # uploaded one.
  #
  # Dated, because criterion 8014 asserts a dump is from *that run* — a key
  # with no date in it cannot answer that, however plausible it looks.
  defp dump_key(environment) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")

    "dumps/#{environment}/app-#{stamp}.sql.gz"
  end

  # A box on the far side of the ssh, answering about itself.
  #
  # Empty was fine while nothing read the output, and stopped being fine the
  # moment the build asked what architecture the image is: `docker image
  # inspect` returning "" arrives as `{:unknown_architecture, ""}`, which reads
  # as a box answering something strange rather than one not answering at all.
  #
  # Matched on the command text because that is what crosses the wire — these
  # are shell strings rather than argv, composed by interpolation in `Remote`.
  defp remote_answer(command) do
    cond do
      String.contains?(command, "{{.Architecture}}") -> "amd64\n"
      String.contains?(command, "/v2/") -> "< HTTP/1.1 200 OK\n"
      String.contains?(command, "uname -m") -> "x86_64\n"
      # The same script, on the box. `bin/backup` runs where `cms-postgres`
      # resolves — the environment's own server — so the backups step passes a
      # `:run` and the command arrives here as one shell line rather than as
      # argv. Answering it in one place keeps the dump and the restore telling
      # the same story, which is what the step checks.
      String.contains?(command, "bin/backup") ->
        command |> backup_args() |> backup(bucket_from(command)) |> elem(0)
      true -> ""
    end
  end

  # `cd /build && export A=b … && bin/backup dump uat` — what follows the
  # script name is what it was called with.
  defp backup_args(command) do
    command
    |> String.split("bin/backup", parts: 2)
    |> List.last()
    |> String.split(~r/\s+/, trim: true)
  end

  # Loudly, so a gap in this shell is a gap rather than a pass.
  defp unmodelled(command, args) do
    {"#{command} #{Enum.join(args, " ")} is not modelled by the shell fake\n", 127}
  end

  # `-f path` is where ssh-keygen puts the key.
  defp key_path(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["-f", path] -> path
      _ -> nil
    end)
  end

  # `sops encrypt --in-place FILE`, `sops decrypt FILE`, `sops set FILE …`.
  # The first argument that looks like a path rather than a flag.
  defp sops_target(args) do
    args
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> Enum.drop(1)
    |> List.first()
  end

  defp sops_command(_env, ["decrypt" | _], _path, contents), do: {contents, 0}

  defp sops_command(env, ["set", _file, key, value | _], path, contents) do
    # `sops set FILE ["KEY"] "json"` — both arguments are JSON, which is how
    # `put_secret/5` encodes them.
    with {:ok, [name]} <- Jason.decode(key),
         {:ok, plain} <- Jason.decode(value) do
      Environments.write_file(env, path, put_line(contents, name, plain))
      {"", 0}
    else
      _ -> {"Error: could not parse #{key} #{value}\n", 1}
    end
  end

  defp sops_command(env, ["encrypt" | _], path, contents) do
    # Idempotent the way sops is, and refusing in sops' own words: `Sops`
    # detects this state by matching the message text, so a fake that refuses
    # with wording of its own reads as a genuine failure and the secrets step
    # reports `{:sops_failed, 1, …}` on a file that is perfectly fine.
    case String.contains?(contents, "# sops:age:") do
      true ->
        {"Error: file is already being encrypted: it has a top-level entry called 'sops'\n", 1}

      false ->
        recipients = recipients_for(env, path)
        Environments.write_file(env, path, contents <> "# sops:age:#{recipients}\n")
        {"", 0}
    end
  end

  defp sops_command(_env, _args, _path, contents), do: {contents, 0}

  # From `.sops.yaml`, which is what real sops reads to decide who can open a
  # file — so a spex that never wrote a config gets a file with no recipient,
  # exactly as it would in the world.
  defp recipients_for(env, path) do
    with {:ok, config} <- Environments.read_file(env, ".sops.yaml"),
         [_ | _] = rules <- String.split(config, "- path_regex: ", trim: true) do
      rules
      |> Enum.find(fn rule -> String.contains?(rule, Path.basename(path)) end)
      |> to_string()
      |> then(&Regex.run(~r/age1[a-z0-9]+/, &1))
      |> case do
        [recipient] -> recipient
        _ -> "age1unconfigured"
      end
    else
      _ -> "age1unconfigured"
    end
  end

  defp put_line(contents, key, value) do
    lines = contents |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#{key}="))
    Enum.join(lines ++ ["#{key}=#{value}"], "\n") <> "\n"
  end

  defp hash(seed), do: :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp listing(env) do
    case Environments.list_directory(env, ".") do
      {:ok, entries} -> entries
      other -> other
    end
  end
end
