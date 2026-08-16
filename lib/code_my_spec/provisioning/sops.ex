defmodule CodeMySpec.Provisioning.Sops do
  @moduledoc """
  Age-encrypted environment files committed to the project's own repo.

  Replaces both AWS SSM and Varlock. One key per environment, so holding
  UAT's key reveals nothing about production.

  ## Why this shells out

  `sops` and `age` are invoked as binaries rather than reimplemented. The
  files have to be decryptable by the real `sops` on the server at boot, so
  the format is not ours to approximate — age is X25519 + ChaCha20-Poly1305
  with bech32 keys wrapped in SOPS's own envelope, and a near-miss
  reimplementation of a credential path is a worse outcome than a dependency.

  Both binaries must be on PATH. When they are not, every function returns
  `{:error, :sops_unavailable}` rather than failing somewhere less obvious.

  ## Plaintext never reaches disk

  `put_secret/4` uses `sops set`, which edits the *encrypted* file in place.
  There is no decrypt-to-tempfile step, so there is no window in which the
  plaintext exists in the working tree and no scratch file for a `git add` to
  sweep up. Criterion 7997 asserts exactly this, and it is why `sops set` is
  used rather than the more obvious decrypt → modify → re-encrypt.

  Verified against the real binaries: after setting a value, the plaintext
  appears nowhere under the project root.

  ## One key per environment

  `.sops.yaml` maps each environment's file to its own recipient via
  `creation_rules`. Confirmed with real keys: a UAT private key given
  production's file fails with "at least one key has to be successful, but
  none were". That is the blast radius criterion 8053 exists to close — with
  one project-wide key, whoever can deploy staging can read production.

  ## The key reaches the server through the deploy

  Decryption takes the private key from the `SOPS_AGE_KEY` environment
  variable, which the deploy tool injects. Nothing writes a key file to the
  host, so there is no key sitting on a box for someone to find, and rotating
  is a re-encrypt plus a redeploy rather than a file edit on a server.
  """

  alias CodeMySpec.Environments
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
  this function — the caller decides where it lives, which for provisioning
  is `ProjectSecrets`, encrypted at rest.
  """
  @spec generate_key() :: {:ok, {String.t(), String.t()}} | error()
  def generate_key do
    with :ok <- ensure_available() do
      # age-keygen writes the public key to stderr and the private key to
      # stdout. Capture both — otherwise the public key leaks to the console
      # and parse_key/1 only ever sees half of what it needs.
      case System.cmd("age-keygen", [], stderr_to_stdout: true) do
        {stdout, 0} -> parse_key(stdout)
        {out, status} -> {:error, {:sops_failed, status, out}}
      end
    end
  end

  @doc """
  The public half of a private age key.

  Exists so the two halves of the pair can be compared. `.sops.yaml` is a
  tracked file naming the public recipient; the private key is a row in the
  database. Nothing kept them in step, and when they drift `sops` can still
  encrypt — it only needs the recipient — while nothing can decrypt. Deriving
  the public key from what is actually stored is the only way to ask whether
  the pair still works without holding a file it can open.
  """
  @spec public_key(String.t()) :: {:ok, String.t()} | error()
  def public_key(private_key) when is_binary(private_key) do
    with :ok <- ensure_available() do
      # `-y` derives rather than generates. Via a file, not stdin, because
      # `System.cmd/3` cannot write to a child's stdin — and not via a shell
      # either, which would put the private key on a command line. Written
      # 0600 in a directory of its own and removed immediately.
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
  # own line. Both are needed: the public one goes in .sops.yaml, the private
  # one goes to the deploy.
  defp parse_key(output) do
    public = Regex.run(~r/age1[a-z0-9]+/, output)
    private = Regex.run(~r/AGE-SECRET-KEY-[A-Z0-9]+/, output)

    case {public, private} do
      {[pub], [priv]} -> {:ok, {pub, priv}}
      _ -> {:error, :unparsable_key}
    end
  end

  @doc """
  Write `.sops.yaml` mapping each environment's file to its own recipient.

  `recipients` is a map of environment name to age public key. Rewriting it
  is safe and idempotent — the file is fully derived from this map.
  """
  @spec write_config(Environments.Environment.t(), %{env_name() => String.t()}) ::
          :ok | {:error, term()}
  def write_config(env, recipients) when is_map(recipients) do
    Environments.write_file(env, @sops_config, render_config(recipients))
  end

  defp render_config(recipients) do
    rules =
      recipients
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, recipient} ->
        """
          - path_regex: #{Regex.escape(env_file(name))}$
            age: #{recipient}\
        """
      end)

    """
    # Generated by CodeMySpec provisioning. One recipient per environment —
    # a key for one environment cannot open another's file.
    creation_rules:
    #{rules}
    """
  end

  @doc "Path of an environment's encrypted file, relative to the project root."
  @spec env_file(env_name()) :: String.t()
  def env_file(name), do: "envs/#{name}.enc.env"

  @doc """
  Set one secret in an environment's encrypted file.

  Edits the ciphertext in place — the plaintext is passed as an argument to
  `sops set` and never written to the working tree.

  The environment's **private** key is required, and that is not an
  implementation detail worth hiding: `sops set` has to decrypt the file's
  data key before it can add a value, so writing a secret to production means
  holding production's key. Taking it as an argument makes that visible at
  every call site rather than depending on an ambient `SOPS_AGE_KEY` that
  happens to be exported.
  """
  @spec put_secret(
          Environments.Environment.t(),
          env_name(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok | error()
  def put_secret(env, environment, key, value, private_key)
      when is_binary(key) and is_binary(value) and is_binary(private_key) do
    with :ok <- ensure_available(),
         :ok <- ensure_file(env, environment) do
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
  @spec decrypt(Environments.Environment.t(), env_name(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | error()
  def decrypt(env, environment, private_key) when is_binary(private_key) do
    with :ok <- ensure_available() do
      args = ["decrypt", env_file(environment)]

      case sops(env, args, cd: env.cwd, env: [{"SOPS_AGE_KEY", private_key}]) do
        {out, 0} -> {:ok, parse_dotenv(out)}
        {out, status} -> {:error, {:sops_failed, status, out}}
      end
    end
  end

  @doc """
  Recipients recorded in an environment's encrypted file.

  Read from the file itself rather than from `.sops.yaml`, because the file is
  what actually governs who can decrypt it — a `.sops.yaml` edited after
  encryption says nothing about existing ciphertext. This is what the status
  page renders as each environment's key fingerprint.
  """
  @spec recipients(Environments.Environment.t(), env_name()) ::
          {:ok, [String.t()]} | {:error, term()}
  def recipients(env, environment) do
    with {:ok, contents} <- Environments.read_file(env, env_file(environment)) do
      {:ok, Regex.scan(~r/age1[a-z0-9]+/, contents) |> List.flatten() |> Enum.uniq()}
    end
  end

  @doc """
  Keys required for boot that the environment's file does not carry.

  Returns the names, so a refusing boot can say which secret is missing
  instead of failing later on whatever code path needed it (criterion 8000).

  A file that does not exist yet carries nothing, so everything required is
  missing. Asking sops to decrypt it instead exits 100 with "cannot operate on
  non-existent file", and that tuple reached the setup page verbatim on the
  first deploy of every new project — the one moment the answer is most
  obviously "you have not set any secrets yet". The state is ordinary rather
  than exceptional: `secrets` mints the key and writes `.sops.yaml`, and the
  file itself only appears when a first secret is set.
  """
  @spec missing_secrets(Environments.Environment.t(), env_name(), String.t(), [String.t()]) ::
          {:ok, [String.t()]} | error()
  def missing_secrets(env, environment, private_key, required) do
    case Environments.file_exists?(env, env_file(environment)) do
      false ->
        {:ok, required}

      true ->
        with {:ok, present} <- decrypt(env, environment, private_key) do
          {:ok, Enum.reject(required, &Map.has_key?(present, &1))}
        end
    end
  end

  ## Internals

  defp ensure_available do
    case available?() do
      true -> :ok
      false -> {:error, :sops_unavailable}
    end
  end

  # `sops set` requires the file to exist and be encrypted already. A fresh
  # environment has neither, so seed it with a placeholder and encrypt — the
  # alternative is a special-case first-secret path that behaves differently
  # from every subsequent one.
  defp ensure_file(env, environment) do
    path = env_file(environment)

    # Encrypted, not merely present. Writing the placeholder and encrypting it
    # are two steps, so anything that interrupts between them leaves plaintext
    # sitting at the `.enc.env` path — and trusting the filename accepted that
    # forever: the step reported done, re-running it changed nothing, and every
    # deploy failed its pre-flight with "sops metadata not found" while
    # pointing at the wrong step.
    #
    # A file whose name asserts encryption that was never applied is the part
    # worth refusing to guess about, so this asks sops rather than the
    # filesystem, and repairs what it finds instead of reporting done over it.
    case Environments.file_exists?(env, path) do
      true ->
        ensure_encrypted(env, path)

      _ ->
        with :ok <- Environments.write_file(env, path, "SOPS_INITIALIZED=true\n") do
          ensure_encrypted(env, path)
        end
    end
  end

  # Always attempt the encrypt, and treat sops' own "this is already
  # encrypted" refusal as success.
  #
  # Not `sops decrypt` as the test: that needs the private key, which is not in
  # scope here, so every encrypted file would read as plaintext and then fail
  # the re-encrypt for the opposite reason. Asking sops to encrypt answers both
  # questions with the key it does have — the recipient.
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

  # `cd` matters: sops resolves `.sops.yaml` from the process working
  # directory, not from the file being encrypted. Running from the project
  # root with relative paths is what makes the creation_rules apply — an
  # absolute path with the wrong cwd fails with "config file not found, or
  # has no creation rules".
  #
  # Through `Environments.cmd/4` rather than `System.cmd/3`, so this runs
  # wherever the environment says it runs. Every other command in provisioning
  # already goes that way; sops was the exception, and the exception was
  # invisible until a test modelled the shell and watched the real binary run
  # anyway (15193154). `Local.cmd/4` applies the environment's cwd itself and
  # passes the rest through, so nothing about the sops semantics changes.
  defp sops(env, args, opts) do
    Environments.cmd(env, "sops", args, [stderr_to_stdout: true] ++ opts)
  end

  defp parse_dotenv(output) do
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
