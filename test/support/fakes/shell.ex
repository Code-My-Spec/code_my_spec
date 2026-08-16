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

  # -- git: the two the steps use --

  defp run(_env, "git", ["rev-parse" | _], _opts), do: {"#{hash("HEAD")}\n", 0}
  defp run(_env, "git", ["archive" | _], _opts), do: {"", 0}
  defp run(_env, "git", _args, _opts), do: {"", 0}

  # -- ssh: a box that answers. What it answers *about* is the drill's --

  defp run(_env, "ssh", args, _opts), do: {remote_answer(Enum.join(args, " ")), 0}
  defp run(_env, "scp", _args, _opts), do: {"", 0}

  # `sh -c "git archive … | ssh … tar -x"` is how a tree reaches a box. The
  # pipeline's effect is on the far side, which nothing here reads.
  defp run(_env, "sh", ["-c" | _], _opts), do: {"", 0}

  # -- the generated scripts, run by absolute path out of the checkout --
  #
  # `bin/deploy <command> <environment>` is what the deploy step shells out to,
  # and what its failure text quotes back — so what matters is the exit status
  # and that the environment named reaches the answer. The work it stands for
  # (kamal pushing an image, running a migration, swapping traffic) happens on
  # a box, and nothing on this side reads it.
  defp run(_env, command, args, _opts) do
    case Path.basename(command) do
      "deploy" -> {"deployed #{Enum.join(args, " ")}\n", 0}
      "backup" -> {"backup complete\n", 0}
      "migrate" -> {"migrated\n", 0}
      _ -> unmodelled(command, args)
    end
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
      true -> ""
    end
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
