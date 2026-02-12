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
      env: [
        {"MIX_ENV", "test"},
        {"DIAGNOSTICS_OUTPUT", output_file}
      ]
    ]

    cmd_opts = if cwd, do: Keyword.put(cmd_opts, :cd, cwd), else: cmd_opts

    {output, exit_code} =
      System.cmd("mix", ["compile", "--return-errors"], cmd_opts)
      |> IO.inspect(label: :compile_output)

    result_data =
      case File.read(output_file) do
        {:ok, content} when byte_size(content) > 0 ->
          parse_jsonl(content)

        {:ok, _} ->
          # file exists but empty — compilation clean, no diagnostics
          []

        _ ->
          # Diagnostics file wasn't written or is empty — fall back to parsing raw output
          Logger.warning("Diagnostics file not available, falling back to raw output parsing")
          parse_raw(output)
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

  # Parse raw compiler output into diagnostic structs
  # Fallback for when the diagnostics JSONL file isn't available
  def parse_raw(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> extract_diagnostics([])
    |> Enum.reverse()
  end

  def parse_raw(output), do: output

  # Extract diagnostics from lines of output
  defp extract_diagnostics([], acc), do: acc

  defp extract_diagnostics([line | rest], acc) do
    if String.starts_with?(line, "== Compilation error") do
      {diagnostic, remaining} = parse_compilation_error(line, rest)
      extract_diagnostics(remaining, [diagnostic | acc])
    else
      extract_diagnostics(rest, acc)
    end
  end

  # Parse a compilation error block
  defp parse_compilation_error(first_line, rest) do
    file =
      case Regex.run(~r/== Compilation error in file (.+?) ==/, first_line) do
        [_, file] -> file
        _ -> nil
      end

    {error_type, message, location, remaining} = parse_error_details(rest)

    diagnostic = %CodeMySpec.Compile.Diagnostic{
      severity: :error,
      message: "#{error_type}: #{message}",
      file: file || location[:file],
      position: if(location, do: %{line: location[:line]}, else: nil)
    }

    {diagnostic, remaining}
  end

  defp parse_error_details([line | rest]) do
    {error_type, message} =
      case Regex.run(~r/^\*\*\s*\(([^)]+)\)\s*(.+)$/, line) do
        [_, error_type, msg] -> {error_type, String.trim(msg)}
        _ -> {"Error", String.trim(line)}
      end

    {location, remaining} = extract_location(rest)

    {error_type, message, location, remaining}
  end

  defp parse_error_details([]), do: {"Error", "", nil, []}

  defp extract_location([line | rest] = lines) do
    case Regex.run(~r/└─\s+([^:]+):(\d+)(?::(\d+))?/, line) do
      [_, file, line_num | _] ->
        location = %{file: file, line: String.to_integer(line_num)}
        {location, rest}

      nil ->
        if String.trim(line) == "" or String.starts_with?(line, "==>") or
             String.contains?(line, "Compiling") do
          {nil, lines}
        else
          extract_location(rest)
        end
    end
  end

  defp extract_location([]), do: {nil, []}

  defp create_temp_file_path do
    temp_dir = System.tmp_dir!()
    filename = "compile_diagnostics_#{System.unique_integer([:positive])}.jsonl"
    Path.join(temp_dir, filename)
  end
end
