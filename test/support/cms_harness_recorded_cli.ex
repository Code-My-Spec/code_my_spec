defmodule CmsHarnessTest.RecordedCli do
  @moduledoc """
  `codex exec` and `claude`, answered from a recording.

  Pinned in `config/test.exs` as the CLI providers' `:command_runner`, so an
  agent launched on `openai-codex` or `claude-code` anywhere in the suite never
  starts the real binary. Before it, every spex whose project connected OpenAI
  ran a real `codex exec` per analysis — about four million uncached tokens a
  day, against the account the fleet works on.

  A recording is keyed by the binary and its subcommand, not the whole command
  line: the arguments carry temp paths and the prompt, which carries the
  transcript, so no two runs ever send the same one. What a criterion here
  asserts is what reached the agent and the page, never what the model said.

  An unrecorded call raises. `SPEX_CASSETTE_MODE=record` runs it for real once
  and writes the answer to `test/fixtures/cli_recordings/agent_cli.json`.
  """

  @path "test/fixtures/cli_recordings/agent_cli.json"

  @spec run(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(executable, args, opts) do
    key = key(executable, args)
    recordings = recordings()

    case recordings do
      %{^key => %{"output" => output, "exit_code" => code}} ->
        write_last_message(args, output)
        {output, code}

      _ ->
        record_or_refuse(key, executable, args, opts, recordings)
    end
  end

  # What `codex exec` leaves beside its stdout, and where Alloy reads the reply
  # from: the final agent message, at the path after `--output-last-message`.
  defp write_last_message(args, output) do
    with [_flag, path | _] <- Enum.drop_while(args, &(&1 != "--output-last-message")),
         text when is_binary(text) <- last_agent_message(output) do
      File.write!(path, text)
    end
  end

  defp last_agent_message(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => t}}} ->
          [t]

        _ ->
          []
      end
    end)
    |> List.last()
  end

  defp record_or_refuse(key, executable, args, opts, recordings) do
    if System.get_env("SPEX_CASSETTE_MODE") == "record" do
      # Through `sh` for one thing: stdin from /dev/null. `System.cmd` leaves it
      # open, and `codex exec` given its prompt as an argument still waits on it.
      {output, code} =
        System.cmd("sh", ["-c", ~s(exec "$0" "$@" < /dev/null), executable | args], opts)

      entry = %{"output" => output, "exit_code" => code, "recorded_at" => DateTime.utc_now()}
      File.write!(@path, Jason.encode!(Map.put(recordings, key, entry), pretty: true))
      {output, code}
    else
      raise "no recording of `#{key}` in #{@path}. A test reached a real agent CLI; " <>
              "run it once with SPEX_CASSETTE_MODE=record to record one."
    end
  end

  # `codex exec` and `codex exec resume` answer differently — a resume carries no
  # new thread — so the subcommand is part of the key.
  defp key(executable, ["exec", "resume" | _]), do: Path.basename(executable) <> " exec resume"
  defp key(executable, ["exec" | _]), do: Path.basename(executable) <> " exec"
  defp key(executable, _args), do: Path.basename(executable)

  defp recordings do
    case File.read(@path) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :enoent} -> %{}
    end
  end
end
