defmodule CodeMySpec.Compile do
  @moduledoc """
  Compile context for executing and parsing Elixir compilation results.
  Provides a clean functional interface for compilation execution and diagnostics analysis.

  Requires the target project to have `:diagnostics` (and optionally `:spex`) in its
  compilers list via `client_utils`. The `:diagnostics` compiler writes a JSONL file
  containing all diagnostics from every compiler in the pipeline.
  """

  require Logger

  @doc """
  Execute mix compile synchronously and read the diagnostics JSONL file.

  Runs `mix compile --return-errors` with `DIAGNOSTICS_OUTPUT` set to a temp file.
  The `:diagnostics` compiler (from client_utils) writes all diagnostics to that file.

  ## Options

  - `cwd` - Working directory to run the command in (optional)
  - `output_file` - Path for diagnostics JSONL output (optional, defaults to temp file)

  ## Returns

  Map with structure:
  ```
  %{
    status: :ok | :error,
    data: %{compiler_results: [map()] | string},
    exit_code: integer,
    output_file: string
  }
  ```
  """
  @spec execute(keyword()) :: map()
  def execute(opts \\ []) do
    output_file = Keyword.get_lazy(opts, :output_file, &create_temp_file_path/0)
    cwd = Keyword.get(opts, :cwd)

    cmd_opts = [
      stderr_to_stdout: true,
      # clean_otp_env clears the Burrito release's ROOTDIR/BINDIR/RELEASE_*
      # so the child `mix`/`erl` boots from the user's installed OTP, not our
      # extracted ERTS (which otherwise crashes with "cannot get bootfile").
      env:
        [
          {"MIX_ENV", "test"},
          {"DIAGNOSTICS_OUTPUT", output_file}
        ] ++ CodeMySpec.Environments.clean_otp_env()
    ]

    cmd_opts = if cwd, do: Keyword.put(cmd_opts, :cd, cwd), else: cmd_opts

    Logger.debug("[Compile] output_file=#{output_file}")
    Logger.debug("[Compile] cwd=#{inspect(cwd)}")
    Logger.debug("[Compile] env=#{inspect(cmd_opts[:env])}")

    {output, exit_code} =
      System.cmd("mix", ["compile", "--return-errors"], cmd_opts)

    Logger.debug("[Compile] exit_code=#{exit_code}")
    Logger.debug("[Compile] output_file exists?=#{File.exists?(output_file)}")
    Logger.debug("[Compile] raw output (first 500 chars): #{String.slice(output, 0, 500)}")

    result_data =
      case File.read(output_file) do
        {:ok, content} when byte_size(content) > 0 ->
          Logger.debug("[Compile] Read JSONL from diagnostics file (#{byte_size(content)} bytes)")
          parse_jsonl(content)

        {:ok, _} ->
          Logger.debug("[Compile] Diagnostics file exists but empty — clean compilation")
          []

        {:error, _reason} when exit_code == 0 ->
          Logger.debug(
            "[Compile] Diagnostics file not found but compilation succeeded — treating as clean"
          )

          []

        {:error, _reason} ->
          # Non-zero exit, no diagnostics file. This is NOT automatically a code
          # error: a config/mix.exs change forcing a rebuild, the "you must
          # restart after changing configuration files" RuntimeError, build-lock
          # contention, or a project missing the :diagnostics compiler all exit
          # non-zero with no diagnostics. Only synthesize a blocking problem when
          # the raw output actually contains a genuine compiler error marker;
          # otherwise treat it as transient so the stop hook isn't blocked by a
          # phantom error parsed out of Mix's progress banner ("==> boundary").
          case extract_compiler_errors(output) do
            [] ->
              Logger.warning(
                "[Compile] exit #{exit_code}, no diagnostics file and no compiler error " <>
                  "markers in output — treating as transient (config change, lock " <>
                  "contention, or missing :diagnostics compiler). First 500 chars: " <>
                  String.slice(output, 0, 500)
              )

              []

            errors ->
              Logger.warning(
                "[Compile] exit #{exit_code}, diagnostics file not written; recovered " <>
                  "#{length(errors)} compiler error(s) from raw output"
              )

              errors
          end
      end

    %{
      status: if(exit_code == 0, do: :ok, else: :error),
      data: %{compiler_results: result_data},
      exit_code: exit_code,
      output_file: output_file
    }
  end

  @doc """
  Execute mix compile asynchronously with callback.

  Wraps `execute/1` in a Task and invokes the callback when complete.

  ## Parameters

  - `opts` - Options to pass to `execute/1` (e.g., `cwd: "/path"`)
  - `interaction_id` - Interaction identifier for status updates
  - `on_complete` - Callback function invoked with compilation results

  ## Returns

  `:ok` - Compilation started successfully in background task
  """
  @spec execute_async(keyword(), String.t(), (map() -> any())) :: :ok
  def execute_async(opts, _interaction_id, on_complete) do
    Task.start(fn ->
      result = execute(opts)
      on_complete.(result)
    end)

    :ok
  end

  @doc """
  Parse JSONL content (one JSON object per line) into a list of maps.
  """
  def parse_jsonl(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{"message" => line, "severity" => "error"}
      end
    end)
  end

  # Markers that prove the raw compiler output contains a genuine code error.
  @compiler_error_markers [
    "** (CompileError)",
    "** (SyntaxError)",
    "** (TokenMissingError)",
    "== Compilation error in file"
  ]

  # Markers that prove a non-zero exit is an infrastructure/transient condition,
  # not a code error. When present we never synthesize a blocking problem.
  @transient_markers [
    "could not compile application",
    "You must restart your server"
  ]

  @doc """
  Extract genuine compiler errors from raw `mix compile` stdout.

  Used only as a fallback when the `:diagnostics` JSONL file was not written and
  the compile exited non-zero. Returns a list of `%{"message" => ..., "severity"
  => "error"}` maps for each genuine error line, or `[]` when the output is a
  transient/infrastructure failure (config change "must restart", lock
  contention) or merely Mix progress banners with no real diagnostics.
  """
  @spec extract_compiler_errors(String.t()) :: [map()]
  def extract_compiler_errors(output) when is_binary(output) do
    if Enum.any?(@transient_markers, &String.contains?(output, &1)) do
      []
    else
      output
      |> String.split("\n")
      |> Enum.filter(&compiler_error_line?/1)
      |> Enum.map(&%{"message" => String.trim(&1), "severity" => "error"})
    end
  end

  defp compiler_error_line?(line) do
    trimmed = String.trim_leading(line)

    Enum.any?(@compiler_error_markers, &String.starts_with?(trimmed, &1)) or
      String.starts_with?(trimmed, "error:")
  end

  defp create_temp_file_path do
    temp_dir = System.tmp_dir!()
    filename = "compile_diagnostics_#{System.unique_integer([:positive])}.jsonl"
    Path.join(temp_dir, filename)
  end
end
