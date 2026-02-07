defmodule CodeMySpec.Compile do
  @moduledoc """
  Compile context for executing and parsing Elixir compilation results.
  Provides a clean functional interface for compilation execution and diagnostics analysis.
  """

  require Logger

  @doc """
  Execute mix compile.machine synchronously with output file handling.

  Runs `mix compile.machine --output <temp_file> --format raw` and handles the result:
  - Exit code 0: File was written successfully, read it
  - Exit code 1: File wasn't written, write collected output to it manually

  ## Options

  - `cwd` - Working directory to run the command in (optional)
  - `output_file` - Path for compilation output JSON (optional, defaults to temp file)

  ## Returns

  Map with structure:
  ```
  %{
    status: :ok | :error,
    data: %{compiler_results: json_map | string},
    exit_code: integer,
    output_file: string
  }
  ```

  ## Example

      result = Compile.execute()
      # result.output_file contains path to JSON output

      result = Compile.execute(cwd: "/path/to/project")
      # Runs compilation in specified directory
  """
  @spec execute(keyword()) :: map()
  def execute(opts \\ []) do
    output_file = Keyword.get_lazy(opts, :output_file, &create_temp_file_path/0)
    cwd = Keyword.get(opts, :cwd)

    # Build System.cmd options
    cmd_opts = [
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}]
    ]

    cmd_opts = if cwd, do: Keyword.put(cmd_opts, :cd, cwd), else: cmd_opts

    # Run compilation using System.cmd
    {output, exit_code} =
      System.cmd("mix", ["compile.machine", "--output", output_file, "--format", "raw"], cmd_opts)

    # Handle result based on exit code
    result_data =
      case exit_code do
        0 ->
          # Command succeeded and wrote the output file
          case File.read(output_file) do
            {:ok, content} ->
              parse_json(content)

            {:error, reason} ->
              Logger.error("Failed to read output file: #{inspect(reason)}")
              parse_raw(output)
          end

        1 ->
          # Parse raw output and write diagnostics as JSON
          parsed_diagnostics = parse_raw(output)

          # Convert diagnostics to maps and encode as JSON
          diagnostics_as_maps = Enum.map(parsed_diagnostics, &Map.from_struct/1)
          json_content = Jason.encode!(diagnostics_as_maps)
          File.write(output_file, json_content)

          parsed_diagnostics

        _ ->
          # Other exit code - return raw output
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
  Execute mix compile.machine asynchronously with callback.

  Wraps `execute/1` in a Task and invokes the callback when complete.

  ## Parameters

  - `opts` - Options to pass to `execute/1` (e.g., `cwd: "/path"`)
  - `interaction_id` - Interaction identifier for status updates
  - `on_complete` - Callback function invoked with compilation results

  ## Returns

  `:ok` - Compilation started successfully in background task

  ## Example

      Compile.execute_async(
        [cwd: "/path/to/project"],
        interaction_id,
        fn result ->
          # Handle completion
          Sessions.handle_result(scope, session_id, interaction_id, result)
        end
      )
  """
  @spec execute_async(keyword(), String.t(), (map() -> any())) :: :ok
  def execute_async(opts, _interaction_id, on_complete) do
    Task.start(fn ->
      # Execute compilation
      result = execute(opts)

      # Invoke callback
      on_complete.(result)
    end)

    :ok
  end

  # Parse raw compiler output into diagnostic structs
  # This is a "reasonable, not perfect" parser for text output
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
    # Match compilation error blocks: "== Compilation error in file <file> =="
    if String.starts_with?(line, "== Compilation error") do
      {diagnostic, remaining} = parse_compilation_error(line, rest)
      extract_diagnostics(remaining, [diagnostic | acc])
    else
      # Skip all other lines (including warnings)
      extract_diagnostics(rest, acc)
    end
  end

  # Parse a compilation error block
  defp parse_compilation_error(first_line, rest) do
    # Extract file from first line: "== Compilation error in file lib/errors.ex =="
    file =
      case Regex.run(~r/== Compilation error in file (.+?) ==/, first_line) do
        [_, file] -> file
        _ -> nil
      end

    # Next line should be the error type and message: "** (ErrorType) message"
    {error_type, message, location, remaining} = parse_error_details(rest)

    diagnostic = %CodeMySpec.Compile.Diagnostic{
      severity: :error,
      message: "#{error_type}: #{message}",
      file: file || location[:file],
      position: if(location, do: %{line: location[:line]}, else: nil)
    }

    {diagnostic, remaining}
  end

  # Parse error details from the lines following the compilation error header
  defp parse_error_details([line | rest]) do
    # Extract error type and message: "** (SyntaxError) invalid syntax found on lib/errors.ex:16:1:"
    {error_type, message} =
      case Regex.run(~r/^\*\*\s*\(([^)]+)\)\s*(.+)$/, line) do
        [_, error_type, msg] -> {error_type, String.trim(msg)}
        _ -> {"Error", String.trim(line)}
      end

    # Look for location in subsequent lines
    {location, remaining} = extract_location(rest)

    {error_type, message, location, remaining}
  end

  defp parse_error_details([]), do: {"Error", "", nil, []}

  # Extract file location from subsequent lines
  defp extract_location([line | rest] = lines) do
    case Regex.run(~r/└─\s+([^:]+):(\d+)(?::(\d+))?/, line) do
      [_, file, line_num | _] ->
        location = %{file: file, line: String.to_integer(line_num)}
        {location, rest}

      nil ->
        # Check if we should continue looking or stop
        if String.trim(line) == "" or String.starts_with?(line, "==>") or
             String.contains?(line, "Compiling") do
          {nil, lines}
        else
          extract_location(rest)
        end
    end
  end

  defp extract_location([]), do: {nil, []}

  # Parse JSON and return decoded data
  defp parse_json(json_string) do
    Jason.decode!(json_string)
  end

  defp create_temp_file_path do
    temp_dir = System.tmp_dir!()
    filename = "compile_machine_#{System.unique_integer([:positive])}.json"
    Path.join(temp_dir, filename)
  end
end
