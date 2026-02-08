defmodule CodeMySpec.Environments.Local do
  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour

  alias CodeMySpec.Environments.Environment

  @impl true
  def create(opts) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    {:ok, %Environment{type: :local, cwd: working_dir}}
  end

  @impl true
  def destroy(_env), do: :ok

  @impl true
  def read_file(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.read(resolved_path)
  end

  @impl true
  def list_directory(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.ls(resolved_path)
  end

  @impl true
  def write_file(env, path, content) do
    resolved_path = resolve_path(path, env.cwd)

    with :ok <- File.mkdir_p(Path.dirname(resolved_path)) do
      File.write(resolved_path, content)
    end
  end

  @impl true
  def delete_file(env, path) do
    resolved_path = resolve_path(path, env.cwd)

    case File.rm(resolved_path) do
      :ok -> :ok
      # File doesn't exist, that's fine
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def file_exists?(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.exists?(resolved_path)
  end

  @impl true
  def glob(env, pattern) do
    resolved_pattern = resolve_path(pattern, env.cwd)
    Path.wildcard(resolved_pattern)
  end

  @impl true
  def environment_setup_command(_env, %{}) do
    ""
  end

  @impl true
  def docs_environment_teardown_command(_env, %{
        context_name: context_name,
        context_type: context_type,
        working_dir: working_dir,
        design_file_name: design_file_name,
        branch_name: branch_name
      }) do
    """
    git -C #{working_dir} add #{design_file_name} && \
    git -C #{working_dir} commit -m "created #{context_type} design for #{context_name}" && \
    git -C #{working_dir} switch main && \
    git -C #{working_dir} merge #{branch_name}
    """
  end

  @impl true
  def test_environment_teardown_command(_env, %{
        context_name: context_name,
        working_dir: working_dir,
        test_file_name: test_file_name,
        branch_name: branch_name
      }) do
    """
    git -C #{working_dir} add #{test_file_name} && \
    git -C #{working_dir} commit -m "generated tests for #{context_name}" && \
    git -C #{working_dir} push -u origin #{branch_name} && \
    gh pr create --title "Add tests for #{context_name}" --body "Automated test generation for #{context_name} component"
    """
  end

  @impl true
  def code_environment_teardown_command(_env, %{
        context_name: context_name,
        working_dir: working_dir,
        code_file_name: code_file_name,
        test_file_name: test_file_name,
        branch_name: branch_name
      }) do
    """
    git -C #{working_dir} add #{code_file_name} #{test_file_name} && \
    git -C #{working_dir} commit -m "implemented #{context_name}" && \
    git -C #{working_dir} push -u origin #{branch_name} && \
    gh pr create --title "Implement #{context_name}" --body "Automated implementation of #{context_name} component"
    """
  end

  def cmd(command, args, opts) do
    case System.cmd(command, args, opts) do
      {output, 0} -> {clean_terminal_output(output), 0}
      {output, exit_code} -> {clean_terminal_output(output), exit_code}
    end
  end

  defp clean_terminal_output(output) do
    output
    |> remove_ansi_codes()
    |> ensure_valid_utf8()
    |> String.trim()
  end

  # Remove ANSI escape codes (colors, formatting, etc.)
  defp remove_ansi_codes(text) do
    String.replace(text, ~r/\x1b\[[0-9;]*m/, "")
  end

  # Ensure the string contains only valid UTF-8 characters
  defp ensure_valid_utf8(text) do
    text
    |> remove_null_bytes()
    |> remove_control_characters()
    |> ensure_printable_utf8()
  end

  # Remove null bytes that PostgreSQL can't handle
  defp remove_null_bytes(text) do
    String.replace(text, <<0>>, "")
  end

  # Remove other problematic control characters
  defp remove_control_characters(text) do
    # Remove control characters except for common ones like \n, \t, \r
    String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  # Ensure we have valid printable UTF-8
  defp ensure_printable_utf8(text) do
    case String.valid?(text) do
      true ->
        text

      false ->
        # Force conversion to valid UTF-8, replacing invalid sequences
        text
        |> :unicode.characters_to_binary(:latin1, :utf8)
        |> case do
          binary when is_binary(binary) -> binary
          # If all else fails, return empty string
          _ -> ""
        end
    end
  end

  # Resolve path relative to working_dir if it's a relative path
  defp resolve_path(path, nil), do: path

  defp resolve_path(path, working_dir) do
    if Path.type(path) == :relative do
      Path.join(working_dir, path) |> Path.absname()
    else
      path
    end
  end
end
