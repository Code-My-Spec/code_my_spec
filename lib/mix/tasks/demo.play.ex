defmodule Mix.Tasks.Demo.Play do
  @shortdoc "Play a Claude Code transcript as a paced terminal session (demo)"

  @moduledoc """
  Cinematic terminal playback of a transcript, in tandem with the harness UI.

      mix demo.play PATH [options]

  Renders the recorded session Claude-Code-style (narration, `⏺` actions, `⎿`
  results) at a watchable pace, while firing the same state-changing ops into
  the harness so the web UI fills in alongside. Run this in the terminal pane
  you're recording, with the project open at http://localhost:4005.

  ## Options

    * `--target DIR`    project dir for file ops (default /tmp/cms_demo_mms)
    * `--mcp-url URL`   harness MCP endpoint (default http://localhost:4005/mcp)
    * `--no-mcp`        render only — don't write to the harness
    * `--source-cwd D`  override recorded cwd for path rewriting
    * `--delay MS`      pause between rendered blocks (playback speed, default 400)
    * `--from N`        start at entry index N
    * `--to N`          stop before entry index N

  Pause for commentary by playing in chunks: `--from 0 --to 40`, narrate,
  then `--from 40 --to 90`.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Transcripts.Player

  @switches [
    target: :string,
    mcp_url: :string,
    no_mcp: :boolean,
    source_cwd: :string,
    delay: :integer,
    from: :integer,
    to: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: @switches)

    path = List.first(paths) || Mix.raise("usage: mix demo.play PATH [--delay MS --from N --to N]")

    {:ok, _} = Application.ensure_all_started(:req)

    mcp_url = if opts[:no_mcp], do: nil, else: opts[:mcp_url] || "http://localhost:4005/mcp"

    play_opts =
      [
        target_dir: opts[:target] || "/tmp/cms_demo_mms",
        mcp_url: mcp_url,
        delay_ms: opts[:delay] || 400
      ]
      |> put_opt(:source_cwd, opts[:source_cwd])
      |> put_opt(:from, opts[:from])
      |> put_opt(:to, opts[:to])

    Player.play(path, play_opts)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
