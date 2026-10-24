defmodule CmsHarness.Attachments.Command do
  @moduledoc false

  alias CodeMySpec.ExecutionContexts

  @limit 1_048_576

  # Keep the launcher (and therefore its owned process group/tree) alive after
  # the foreground result. Detaching can still kill ordinary background children.
  def run(root, command, args, completed) do
    marker = "cms_" <> Base.encode16(:crypto.strong_rand_bytes(16))
    {executable, arguments} = launcher(command, args, marker)
    env = ExecutionContexts.merge_clean_env([])[:env]

    env =
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
      end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: arguments,
        cd: root,
        env: env
      ])

    collect(port, marker, completed, "", "", 0)
  end

  defp launcher(command, args, marker) do
    case :os.type() do
      {:win32, _} ->
        script =
          "& " <>
            quote_ps(command) <>
            " " <>
            Enum.map_join(args, " ", &quote_ps/1) <>
            "; $code = $LASTEXITCODE; if ($null -eq $code) {$code = 0}; [Console]::Out.WriteLine([Environment]::NewLine + '" <>
            marker <> ":' + $code); [Console]::In.ReadLine() | Out-Null"

        encoded =
          script |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> Base.encode64()

        {System.find_executable("powershell.exe"),
         ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]}

      _ ->
        script =
          "\"$@\"; cms_status=$?; printf '\\n" <>
            marker <> ":%s\\n' \"$cms_status\"; read cms_release"

        {"/bin/sh", ["-c", script, "cms-attachment", command | args]}
    end
  end

  defp quote_ps(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp collect(port, marker, completed, output, tail, total) do
    receive do
      {^port, {:data, bytes}} ->
        output =
          output <>
            binary_part(bytes, 0, min(byte_size(bytes), max(@limit - byte_size(output), 0)))

        total = total + byte_size(bytes)
        tail = tail <> bytes

        case Regex.run(Regex.compile!("(?:\\r?\\n)?" <> marker <> ":([0-9]+)\\r?\\n"), tail,
               return: :index
             ) do
          [{offset, _length}, {status_offset, status_length}] ->
            status = tail |> binary_part(status_offset, status_length) |> String.to_integer()
            absolute = total - byte_size(tail) + offset
            output = binary_part(output, 0, min(byte_size(output), absolute))
            completed.({:ok, %{output: clean(output), exit_status: status}})
            hold(port)

          nil ->
            keep = min(byte_size(tail), 256)

            collect(
              port,
              marker,
              completed,
              output,
              binary_part(tail, byte_size(tail) - keep, keep),
              total
            )
        end

      {^port, {:exit_status, status}} ->
        {:error, %{reason: "command_launcher_exited", exit_status: status}}
    end
  end

  defp hold(port) do
    receive do
      {^port, {:data, _bytes}} -> hold(port)
      {^port, {:exit_status, _status}} -> :ok
    end
  end

  defp clean(bytes) do
    for <<char::utf8 <- bytes>>, char != 0, into: "", do: <<char::utf8>>
  end
end
