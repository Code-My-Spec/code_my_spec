defmodule CodeMySpec.Provisioning.Sops do
  @moduledoc """
  Age-encrypted environment files committed to the project's own repo.

  One key per environment, so holding UAT's key reveals nothing about
  production.

  - **Shells out** to the real `sops` and `age`: the server decrypts with the
    real `sops`, so the format is not ours to approximate. Both must be on
    PATH; otherwise every function returns `{:error, :sops_unavailable}`.
  - **Plaintext never reaches disk.** `put_secret/5` uses `sops set`, which
    edits the encrypted file in place.
  - **`.sops.yaml` maps each environment's file to its own recipient.**
  - **The key reaches the server through the deploy** as `SOPS_AGE_KEY`;
    nothing writes a key file to the host.

  See knowledge/provisioning, "Secrets (sops)".
  """

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.TempFile

  @sops_config ".sops.yaml"

  @type env_name :: String.t()
  @type error ::
          {:error, :sops_unavailable}
          | {:error, {:sops_failed, integer(), String.t()}}
          | {:error, term()}

  @doc "Whether both binaries are present. Everything else depends on this."
  @spec available?() :: boolean()
  def available? do
    not is_nil(System.find_executable("sops")) and not is_nil(System.find_executable("age"))
  end

  @doc """
  Generate a fresh age key pair.

  Returns `{public, private}`. The private key is never written to disk by
  this function; provisioning keeps it in `ProjectSecrets`.
  """
  @spec generate_key() :: {:ok, {String.t(), String.t()}} | error()
  def generate_key do
    with :ok <- ensure_available() do
      # age-keygen writes the public key to stderr and the private key to
      # stdout; capture both.
      case System.cmd("age-keygen", [], stderr_to_stdout: true) do
        {stdout, 0} -> parse_key(stdout)
        {out, status} -> {:error, {:sops_failed, status, out}}
      end
    end
  end

  @doc """
  The public half of a private age key.

  Lets the stored private key be checked against `.sops.yaml`'s public
  recipient: when they drift, `sops` can still encrypt but nothing can
  decrypt.
  """
  @spec public_key(String.t()) :: {:ok, String.t()} | error()
  def public_key(private_key) when is_binary(private_key) do
    with :ok <- ensure_available() do
      # `-y` derives rather than generates. Via a 0600 file in its own
      # directory, removed immediately: `System.cmd/3` cannot write a child's
      # stdin, and a shell would put the key on a command line.
      dir = TempFile.dir("cms-age")
      File.mkdir_p!(dir)
      path = Path.join(dir, "key.txt")

      try do
        File.write!(path, private_key)
        File.chmod!(path, 0o600)

        case System.cmd("age-keygen", ["-y", path], stderr_to_stdout: true) do
          {out, 0} ->
            case Regex.run(~r/age1[a-z0-9]+/, out) do
              [public] -> {:ok, public}
              _ -> {:error, :unparsable_key}
            end

          {out, status} ->
            {:error, {:sops_failed, status, out}}
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  # age-keygen prints the public key as a comment and the private key on its
  # own line: the public one goes in .sops.yaml, the private one to the deploy.
  defp parse_key(output) do
    public = Regex.run(~r/age1[a-z0-9]+/, output)
    private = Regex.run(~r/AGE-SECRET-KEY-[A-Z0-9]+/, output)

    case {public, private} do
      {[pub], [priv]} -> {:ok, {pub, priv}}
      _ -> {:error, :unparsable_key}
    end
  end

  @doc """
  Write `.sops.yaml`'s own per-environment rules, keeping every other rule
  already committed there untouched.

  `recipients` is a map of environment name to age public key, and the rule
  this step owns for each is always `envs/<environment>.enc.env$` -- its own
  file naming convention. Issue 5850ece7: metric_flow had its own committed
  rule for a local keyring (`envs/(dev|test)\\.`, a different pattern, for a
  file this step never writes), and rendering the whole file from
  `recipients` alone discarded it on every secrets run. Rewriting *our* own
  rules is still safe and idempotent -- each is fully derived from
  `recipients` -- but any other rule already in the file is read back and
  kept as data, not replaced.
  """
  @spec write_config(ExecutionContexts.ExecutionContext.t(), %{env_name() => String.t()}) ::
          :ok | {:error, term()}
  def write_config(env, recipients) when is_map(recipients) do
    ExecutionContexts.write_file(env, @sops_config, render_config(env, recipients))
  end

  defp render_config(env, recipients) do
    owned = owned_path_regexes(recipients)

    kept =
      env
      |> foreign_rules()
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&(Map.get(&1, "path_regex") in owned))

    own_rules =
      recipients
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, recipient} ->
        "  - path_regex: #{Regex.escape(env_file(name))}$\n    age: #{recipient}"
      end)

    kept_rules = Enum.map_join(kept, "\n", &render_kept_rule/1)

    rules =
      [own_rules, kept_rules]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    """
    # Generated by CodeMySpec provisioning. Rules under envs/<env>.enc.env are
    # this step's own and fully derived from the age keys on file; any other
    # rule already committed here is kept as written, not replaced.
    creation_rules:
    #{rules}
    """
  end

  defp owned_path_regexes(recipients) do
    recipients
    |> Map.keys()
    |> MapSet.new(&(Regex.escape(env_file(&1)) <> "$"))
  end

  # The file's own rules, as data -- read back through the same decoder
  # that reads a config a human or another tool wrote, since this step must
  # not assume its own output is the only shape this file ever takes. A
  # missing file, or one sops has never written to, has nothing to keep.
  defp foreign_rules(env) do
    with {:ok, contents} <- ExecutionContexts.read_file(env, @sops_config),
         {:ok, %{"creation_rules" => rules}} when is_list(rules) <-
           YamlElixir.read_from_string(contents) do
      rules
    else
      _ -> []
    end
  end

  defp render_kept_rule(rule) do
    case Map.to_list(rule) do
      [] ->
        ""

      [{key, value} | rest] ->
        (["  - #{key}: #{render_yaml_scalar(value)}"] ++
           Enum.map(rest, fn {k, v} -> "    #{k}: #{render_yaml_scalar(v)}" end))
        |> Enum.join("\n")
    end
  end

  # Round-trips through `Jason` for strings rather than trying to tell a
  # plain YAML scalar from one that needs quoting -- a kept rule's own
  # values (a path_regex with `|` or `\`, say) are arbitrary, and a JSON
  # string is always a valid YAML one too.
  defp render_yaml_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp render_yaml_scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)

  defp render_yaml_scalar(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &render_yaml_scalar/1) <> "]"

  defp render_yaml_scalar(value) when is_map(value) do
    "{" <>
      Enum.map_join(value, ", ", fn {k, v} ->
        "#{Jason.encode!(to_string(k))}: #{render_yaml_scalar(v)}"
      end) <> "}"
  end

  @doc "Path of an environment's encrypted file, relative to the project root."
  @spec env_file(env_name()) :: String.t()
  def env_file(name), do: "envs/#{name}.enc.env"

  @doc """
  Set one secret in an environment's encrypted file.

  Edits the ciphertext in place — the plaintext is passed as an argument to
  `sops set` and never written to the working tree.

  The environment's **private** key is required: `sops set` decrypts the
  file's data key first. Taking it as an argument makes that visible rather
  than depending on an ambient `SOPS_AGE_KEY`.
  """
  @spec put_secret(
          ExecutionContexts.ExecutionContext.t(),
          env_name(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok | error()
  def put_secret(env, environment, key, value, private_key)
      when is_binary(key) and is_binary(value) and is_binary(private_key) do
    with :ok <- ensure_available() do
      on_this_node(env, environment, :write_back, &set(&1, environment, key, value, private_key))
    end
  end

  defp set(env, environment, key, value, private_key) do
    with :ok <- ensure_file(env, environment) do
      args = ["set", env_file(environment), ~s(["#{key}"]), Jason.encode!(value)]

      case sops(env, args, cd: env.cwd, env: [{"SOPS_AGE_KEY", private_key}]) do
        {_out, 0} -> :ok
        {out, status} -> {:error, {:sops_failed, status, out}}
      end
    end
  end

  @doc """
  Decrypt an environment's file with a private key, returning the parsed
  key/value pairs.

  The key is passed through `SOPS_AGE_KEY` rather than a file, mirroring how
  it reaches the server.
  """
  @spec decrypt(ExecutionContexts.ExecutionContext.t(), env_name(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | error()
  def decrypt(env, environment, private_key) when is_binary(private_key) do
    with :ok <- ensure_available() do
      on_this_node(env, environment, :read_only, &decrypt_here(&1, environment, private_key))
    end
  end

  defp decrypt_here(env, environment, private_key) do
    args = ["decrypt", env_file(environment)]

    case sops(env, args, cd: env.cwd, env: [{"SOPS_AGE_KEY", private_key}]) do
      {out, 0} -> {:ok, parse_dotenv(out)}
      {out, status} -> {:error, {:sops_failed, status, out}}
    end
  end

  @doc """
  Recipients recorded in an environment's encrypted file.

  Read from the file itself rather than `.sops.yaml`: the file governs who can
  decrypt it. The status page renders these as each environment's key.
  """
  @spec recipients(ExecutionContexts.ExecutionContext.t(), env_name()) ::
          {:ok, [String.t()]} | {:error, term()}
  def recipients(env, environment) do
    with {:ok, contents} <- ExecutionContexts.read_file(env, env_file(environment)) do
      {:ok, Regex.scan(~r/age1[a-z0-9]+/, contents) |> List.flatten() |> Enum.uniq()}
    end
  end

  @doc """
  Keys required for boot that the environment's file does not carry.

  Returns the names, so a refusing boot can say which secret is missing.

  A file that does not exist yet, or exists but was never encrypted (the
  generator's plain-text scaffold: "sops metadata not found"), carries
  nothing, so everything required is missing. Neither is an error.
  """
  @spec missing_secrets(ExecutionContexts.ExecutionContext.t(), env_name(), String.t(), [
          String.t()
        ]) ::
          {:ok, [String.t()]} | error()
  def missing_secrets(env, environment, private_key, required) do
    if ExecutionContexts.file_exists?(env, env_file(environment)) do
      case decrypt(env, environment, private_key) do
        {:ok, present} ->
          {:ok, Enum.reject(required, &Map.has_key?(present, &1))}

        {:error, {:sops_failed, _status, output} = reason} ->
          unencrypted_scaffold(reason, output, required)

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, required}
    end
  end

  defp unencrypted_scaffold(reason, output, required) do
    if String.contains?(output, "metadata not found") do
      {:ok, required}
    else
      {:error, reason}
    end
  end

  ## Internals

  # sops is a command, and a harness copy runs no commands: its files are on
  # another machine. So sops runs here, over a temp mirror of `.sops.yaml` and
  # the environment's file, and only the encrypted result is written back.
  # The plaintext stays an argument, as on a local copy.
  defp on_this_node(%{type: type} = env, environment, mode, fun)
       when type in [:harness, :memory] do
    dir = TempFile.owned_dir("cms-sops")
    local = ExecutionContexts.ExecutionContext.new(:local, dir)
    path = env_file(environment)

    try do
      with :ok <- mirror(env, local, @sops_config),
           :ok <- mirror(env, local, path) do
        fun.(local) |> write_back(mode, local, env, path)
      end
    after
      File.rm_rf(dir)
    end
    |> unwrap_read(mode)
  end

  defp on_this_node(env, _environment, _mode, fun), do: fun.(env)

  # `:read_only` results are `{:ok, map}` rather than `:ok`; carried through
  # `write_back/5` untouched and unwrapped after.
  defp write_back(:ok, :write_back, local, remote, path), do: mirror(local, remote, path)
  defp write_back({:ok, _} = read, :read_only, _local, _remote, _path), do: {:read, read}
  defp write_back(other, _mode, _local, _remote, _path), do: other

  defp unwrap_read({:read, read}, :read_only), do: read
  defp unwrap_read(result, _mode), do: result

  defp mirror(from, to, path) do
    if ExecutionContexts.file_exists?(from, path) do
      with {:ok, contents} <- ExecutionContexts.read_file(from, path) do
        ExecutionContexts.write_file(to, path, contents)
      end
    else
      :ok
    end
  end

  defp ensure_available do
    if available?(), do: :ok, else: {:error, :sops_unavailable}
  end

  # `sops set` requires the file to exist and be encrypted already, so a fresh
  # environment is seeded with a placeholder and encrypted.
  defp ensure_file(env, environment) do
    path = env_file(environment)

    # Encrypted, not merely present: an interruption between writing and
    # encrypting leaves plaintext at the `.enc.env` path, so ask sops and
    # repair rather than trusting the filename.
    case ExecutionContexts.file_exists?(env, path) do
      true ->
        ensure_encrypted(env, path)

      _ ->
        with :ok <- ExecutionContexts.write_file(env, path, "SOPS_INITIALIZED=true\n") do
          ensure_encrypted(env, path)
        end
    end
  end

  # Always attempt the encrypt and treat sops' "already encrypted" refusal as
  # success. `sops decrypt` cannot be the test: the private key is not in
  # scope here.
  defp ensure_encrypted(env, path) do
    case sops(env, ["encrypt", "--in-place", path], cd: env.cwd) do
      {_out, 0} ->
        :ok

      {out, status} ->
        if already_encrypted?(out), do: :ok, else: {:error, {:sops_failed, status, out}}
    end
  end

  defp already_encrypted?(output) do
    String.contains?(output, "already being encrypted") or
      String.contains?(output, "top-level entry called 'sops'")
  end

  # `cd` matters: sops resolves `.sops.yaml` from the working directory, so it
  # runs from the project root with relative paths. Through
  # `ExecutionContexts.cmd/4`, so it runs wherever the environment says.
  defp sops(env, args, opts) do
    ExecutionContexts.cmd(env, "sops", args, [stderr_to_stdout: true] ++ opts)
  end

  @doc """
  Parse `KEY=value` lines into a map, skipping comments and blank lines.

  Used both to read back a decrypted file and, by `Steps.import_dotenv/3`,
  to read an app's existing env before any of it reaches `put_secret/5`.
  """
  @spec parse_dotenv(String.t()) :: %{String.t() => String.t()}
  def parse_dotenv(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), value)
        _ -> acc
      end
    end)
  end
end
