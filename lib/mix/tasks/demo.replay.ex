defmodule Mix.Tasks.Demo.Replay do
  @shortdoc "Replay Claude Code transcript(s) into the demo harness sandbox"

  @moduledoc """
  Replays one or more Claude Code transcripts onto the demo project dir and the
  running cli_demo harness, in chronological order.

      mix demo.replay PATH [PATH ...] [options]

  ## Options

    * `--target DIR`    project dir to write into (default /tmp/cms_demo_mms)
    * `--mcp-url URL`   harness MCP endpoint (default http://localhost:4005/mcp)
    * `--no-mcp`        filesystem-only replay (skip harness MCP calls)
    * `--source-cwd D`  override the recorded cwd used for path rewriting
    * `--log LEVEL`     quiet | errors | all (default all when paced)
    * `--delay MS`      pause MS between visible ops for live playback (default 0)
    * `--from N`        start at op index N (inclusive)
    * `--to N`          stop before op index N

  Playback: open the project in the web UI, then play a chunk at a watchable
  speed and pause for commentary, e.g.

      mix demo.replay SESSION --delay 700 --from 0 --to 60
      # narrate, then continue:
      mix demo.replay SESSION --delay 700 --from 60 --to 130

  The harness must already be running (`MIX_ENV=cli_demo mix phx.server`) and a
  project row must authorize the target dir. Transcripts are read directly; the
  originals are never modified.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Transcripts.Replayer

  @switches [
    target: :string,
    mcp_url: :string,
    no_mcp: :boolean,
    source_cwd: :string,
    log: :string,
    delay: :integer,
    from: :integer,
    to: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: @switches)

    if paths == [] do
      Mix.raise("usage: mix demo.replay PATH [PATH ...] [--target DIR] [--mcp-url URL]")
    end

    {:ok, _} = Application.ensure_all_started(:req)

    target = opts[:target] || "/tmp/cms_demo_mms"
    mcp_url = if opts[:no_mcp], do: nil, else: opts[:mcp_url] || "http://localhost:4005/mcp"
    delay = opts[:delay] || 0
    # When paced for playback, default to streaming every op so the operator
    # can follow along; otherwise just surface errors.
    log = String.to_atom(opts[:log] || if(delay > 0, do: "all", else: "errors"))

    replay_opts =
      [mcp_url: mcp_url, log: log, delay_ms: delay]
      |> maybe_put(:from, opts[:from])
      |> maybe_put(:to, opts[:to])
      |> Kernel.++(source_cwd_opt(opts))

    File.mkdir_p!(target)

    IO.puts("target=#{target}  mcp=#{mcp_url || "(filesystem only)"}  sessions=#{length(paths)}\n")

    totals =
      paths
      |> Enum.with_index(1)
      |> Enum.reduce(%Replayer.Result{}, fn {path, i}, acc ->
        IO.puts("[#{i}/#{length(paths)}] #{Path.basename(path)}")

        case Replayer.replay(path, target, replay_opts) do
          {:ok, result} ->
            print_summary(result)
            merge(acc, result)

          {:error, reason} ->
            IO.puts(:stderr, "  ✗ could not replay: #{inspect(reason)}")
            acc
        end
      end)

    IO.puts("\n==== TOTAL ====")
    print_summary(totals)
    print_failures(totals)
  end

  defp source_cwd_opt(opts) do
    case opts[:source_cwd] do
      nil -> []
      cwd -> [source_cwd: cwd]
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_summary(%Replayer.Result{} = r) do
    IO.puts(
      "  files=#{r.file}  mcp_ok=#{r.mcp_ok}  mcp_err=#{r.mcp_err}  " <>
        "errors=#{r.error}  skipped=#{r.skip}  (total #{r.total})"
    )
  end

  defp print_failures(%Replayer.Result{failures: []}), do: :ok

  defp print_failures(%Replayer.Result{failures: failures}) do
    IO.puts("\n---- failures (#{length(failures)}) ----")

    failures
    |> Enum.reverse()
    |> Enum.frequencies_by(fn {name, reason} -> {name, reason} end)
    |> Enum.sort_by(fn {_k, n} -> -n end)
    |> Enum.take(40)
    |> Enum.each(fn {{name, reason}, n} -> IO.puts("  #{n}x #{name}: #{reason}") end)
  end

  defp merge(%Replayer.Result{} = a, %Replayer.Result{} = b) do
    %Replayer.Result{
      file: a.file + b.file,
      skip: a.skip + b.skip,
      mcp_ok: a.mcp_ok + b.mcp_ok,
      mcp_err: a.mcp_err + b.mcp_err,
      error: a.error + b.error,
      total: a.total + b.total,
      failures: b.failures ++ a.failures
    }
  end
end
