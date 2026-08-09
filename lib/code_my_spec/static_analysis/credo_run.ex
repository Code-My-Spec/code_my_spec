defmodule CodeMySpec.StaticAnalysis.CredoRun do
  @moduledoc """
  The device half of the Credo analyzer: run `mix credo` and hand back the
  issues it printed.

  Derived from `CodeMySpec.StaticAnalysis.Analyzers.Credo` on the server, which
  cannot be copied verbatim — its `run/2` finishes by building `%Problems.Problem{}`
  structs against a `%Users.Scope{}`, and both of those are database. What is
  left once those go is this: build the args, shell out through `Environments`,
  find the JSON in the output, and return `issues` exactly as Credo emitted them.

  Conversion to Problems stays on the server, where the schema is. The raw issue
  maps travel over the wire with string keys, which is the shape
  `ProblemConverter.from_credo/1` already accepts.

  ## One deliberate divergence from the original

  The server's analyzer treats unparseable output as `{:ok, []}` — no issues.
  This returns an error instead, because over a wire that answer is
  indistinguishable from a clean sweep and gets recorded as one. A real run
  proved it: a project without `:credo` in its deps printed
  `** (Mix) The task "credo" could not be found`, which is not JSON, and the
  harness reported the project credo-clean. The server never hit that because
  `available?/1` skipped the analyzer first — so that check is here too, ahead
  of everything else.
  """

  require Logger

  alias CodeMySpec.Environments

  @doc """
  Run Credo in `environment` and return its issues.

  ## Options

  - `:files` — restrict the sweep to these paths (relative to the project root)
  - `:config_file` — passed through as `--config-file`

  Returns `{:ok, [issue_map]}` or `{:error, reason}`. An empty list means Credo
  ran and found nothing; a failure to run is an error, never an empty list —
  those two must not arrive at the server as the same answer.
  """
  @spec run(Environments.Environment.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def run(environment, opts \\ []) do
    if available?(environment) do
      execute(environment, opts)
    else
      {:error, "credo is not installed in this project (no deps/credo)"}
    end
  end

  @doc """
  Whether Credo can run against this working copy at all.

  Through `Environments`, not `File`, because the question is whether the tool is
  installed for the `mix` that would actually run — which on a remote environment
  is not this machine's disk. A raw `File.exists?` would inspect the wrong host
  and answer false, skipping the analyzer silently instead of failing.
  """
  @spec available?(Environments.Environment.t()) :: boolean()
  def available?(environment) do
    Environments.exec_file_exists?(environment, "mix.exs") and
      Environments.exec_file_exists?(environment, "deps/credo")
  rescue
    _ -> false
  end

  defp execute(environment, opts) do
    cwd = environment.cwd

    args = build_args(opts, cwd)

    # clean_otp_env keeps the child `mix`/`erl` off a Burrito release's
    # extracted ERTS (see CodeMySpec.Environments.clean_otp_env/0).
    cmd_opts = [
      stderr_to_stdout: true,
      env: Keyword.get(opts, :extra_env, []) ++ Environments.clean_otp_env()
    ]

    Logger.info("[CredoRun] Running: mix #{Enum.join(args, " ")}")

    case Environments.cmd(environment, "mix", args, cmd_opts) do
      {output, exit_code} when exit_code in 0..1 ->
        parse(output)

      # Credo exits >1 for its own failures. Output is still worth parsing when
      # there is any — but no output at all means it never ran, and that is an
      # error rather than a clean sweep.
      {output, exit_code} ->
        if String.trim(output) == "" do
          {:error, "credo exited #{exit_code} with no output"}
        else
          parse(output)
        end
    end
  rescue
    exception ->
      {:error, "credo crashed: #{Exception.message(exception)}"}
  end

  defp build_args(opts, cwd) do
    base = [
      "credo",
      "suggest",
      "--format",
      "json",
      "--all",
      "--all-priorities",
      "--no-color"
    ]

    args =
      case Keyword.get(opts, :config_file) do
        nil -> base
        config_file -> base ++ ["--config-file", config_file]
      end

    case Keyword.get(opts, :files) do
      nil -> args
      [] -> args
      files when is_list(files) -> args ++ make_relative(files, cwd)
    end
  end

  defp make_relative(files, cwd) do
    abs_cwd = Path.expand(cwd)

    Enum.map(files, fn file ->
      abs_file = Path.expand(file)

      case Path.relative_to(abs_file, abs_cwd) do
        ^abs_file -> file
        relative -> relative
      end
    end)
  end

  defp parse(output) do
    case extract_json(output) do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        {:ok, issues}

      {:ok, %{}} ->
        {:ok, []}

      {:ok, _other} ->
        {:error, "unexpected JSON structure from credo"}

      :error ->
        # The server analyzer answers `{:ok, []}` here. Over a wire that is
        # recorded as a clean sweep, so this says it could not read the output
        # instead — the excerpt is carried because the reason is usually in it
        # (`** (Mix) The task "credo" could not be found`, a compile error).
        Logger.warning(
          "[CredoRun] no JSON document in credo's output: " <>
            (output |> String.trim() |> String.slice(0, 200))
        )

        {:error,
         "credo produced output that is not JSON: " <>
           (output |> String.trim() |> String.slice(0, 300))}
    end
  end

  @doc """
  The JSON document credo printed, out of everything else it printed.

  Compilation chatter precedes it, and the obvious reading of that — slice from
  the first `{` — is wrong, because compiler warnings quote Elixir source and
  Elixir source is full of braces. On this repo the first `{` lands 330 bytes
  early, inside `{{:., _, [erl_mod, fun]}, meta, _args} = ast`, and the whole
  sweep is reported as "output that is not JSON". 598 real issues went
  unreported that way, and the failure looks like credo being broken.

  Taking the *last* `{` is wrong too: the document is pretty-printed across
  ~7000 lines, so almost every `{` in the file is one of its own nested objects.

  So: try each `{` in order and keep the first that yields a whole document
  with an `issues` key. Failures are cheap — a slice that is not JSON fails at
  its first byte — and the key requirement is what stops a stray `{}` inside a
  warning from passing for a clean run.
  """
  @spec extract_json(String.t()) :: {:ok, map()} | :error
  def extract_json(output) do
    output
    |> brace_offsets()
    |> Enum.find_value(:error, fn offset ->
      candidate = binary_part(output, offset, byte_size(output) - offset)

      case Jason.decode(String.trim(candidate)) do
        {:ok, %{"issues" => _} = decoded} -> {:ok, decoded}
        _ -> nil
      end
    end)
  end

  # Bounded so that output which is *all* braces and no JSON cannot turn a
  # failed analyzer run into a long one. Credo's document has never been more
  # than a few dozen braces into the output.
  @max_candidates 200

  defp brace_offsets(output) do
    case :binary.matches(output, "{") do
      [] -> []
      matches -> matches |> Enum.take(@max_candidates) |> Enum.map(fn {start, _} -> start end)
    end
  end
end
