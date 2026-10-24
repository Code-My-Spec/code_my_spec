defmodule CmsHarness.Attachments.Operations do
  @moduledoc false

  alias CmsHarness.Attachments.Command

  def execute(root, payload, completed) do
    case payload do
      %{"operation" => "command", "command" => command} when is_binary(command) ->
        args = payload["args"] || []

        if is_list(args) and Enum.all?(args, &is_binary/1),
          do: Command.run(root, command, args, completed),
          else: {:error, :invalid_command_arguments}

      _ ->
        execute(root, payload)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def execute(root, %{"operation" => operation} = payload) do
    with {:ok, path} <- resolve(root, payload["path"] || ".") do
      apply_operation(operation, path, payload)
    end
  end

  def execute(_root, _payload), do: {:error, :invalid_attachment_operation}

  defp apply_operation("read_file", path, _payload) do
    with {:ok, %{size: size}} <- File.stat(path),
         true <- size <= 1_048_576 do
      File.read(path)
    else
      false -> {:error, :file_too_large}
      error -> error
    end
  end

  defp apply_operation("list_directory", path, _payload), do: File.ls(path)

  defp apply_operation("write_file", path, %{"content" => content}) when is_binary(content) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, content)
  end

  defp apply_operation("search", path, %{"pattern" => pattern}) when is_binary(pattern) do
    # Literal content search, bounded results, with no symlink traversal.
    {:ok, search(path, pattern, path, []) |> Enum.take(200)}
  end

  defp apply_operation(_operation, _path, _payload), do: {:error, :invalid_attachment_operation}

  defp search(path, pattern, base, results) when length(results) < 200 do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        search_directory(path, pattern, base, results)

      {:ok, %{type: :regular, size: size}} when size <= 1_048_576 ->
        results ++ matching_lines(path, pattern, base, 200 - length(results))

      _ ->
        results
    end
  end

  defp search(_path, _pattern, _base, results), do: results

  defp search_directory(path, pattern, base, results) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce_while(names, results, &search_entry(&1, &2, path, pattern, base))

      _ ->
        results
    end
  end

  defp search_entry(_name, results, _path, _pattern, _base) when length(results) >= 200,
    do: {:halt, results}

  defp search_entry(name, results, path, pattern, base),
    do: {:cont, search(Path.join(path, name), pattern, base, results)}

  defp matching_lines(path, pattern, base, limit) do
    with {:ok, contents} <- File.read(path), true <- String.valid?(contents) do
      contents
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> String.contains?(line, pattern) end)
      |> Enum.take(limit)
      |> Enum.map(fn {line, n} ->
        %{path: Path.relative_to(path, base), line: n, text: String.slice(line, 0, 2_000)}
      end)
    else
      _ -> []
    end
  end

  defp resolve(root, path) when is_binary(path) do
    if Path.type(path) != :relative or ".." in Path.split(path) do
      {:error, :path_outside_working_copy}
    else
      Enum.reduce_while(Path.split(path), {:ok, root}, &resolve_part/2)
    end
  end

  defp resolve(_root, _path), do: {:error, :invalid_path}

  defp resolve_part(part, {:ok, current}) do
    next = Path.join(current, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_path_not_allowed}}
      _ -> {:cont, {:ok, next}}
    end
  end
end
