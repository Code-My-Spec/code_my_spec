defmodule Mix.Tasks.Demo.Video do
  @shortdoc "Record a two-pane mp4 (terminal + harness UI) of a transcript replay"

  @moduledoc """
  Records one continuous side-by-side mp4: terminal (Player) on the left, the
  live harness UI on the right, both captured in parallel from the same paced
  Player loop. Optional pacing schedule fast-forwards through plumbing and
  slows on money beats — one video, no cuts.

      mix demo.video SESSION_PATH [options]

  ## Options

    * `--view KEY`      browser pane key (default: stories)
                        stories | graph | files | issues | architecture |
                        three-amigos:STORY_ID | story:STORY_ID | <raw URL>
    * `--from N`        start at entry index N (default: 0)
    * `--to N`          stop before entry index N (default: end)
    * `--delay MS`      ms between blocks if no --pacing (default: 200)
    * `--pacing SPEC`   variable pacing: "0:80,200:600,500:80,700:1200"
    * `--output PATH`   final mp4 (default: /tmp/demo.mp4)
    * `--viewport WxH`  browser viewport (default: 1280x800)

  Preconditions: cli_demo harness on :4005, demo server on :4006, project
  pre-seeded, Playwright workspace at /tmp/cms_demo_video (npm install playwright).
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  @workspace "/tmp/cms_demo_video"
  @cast "/tmp/play.cast"
  @terminal_mp4 "/tmp/terminal.mp4"
  @browser_mp4 "/tmp/browser.mp4"
  @switches [
    view: :string,
    from: :integer,
    to: :integer,
    delay: :integer,
    pacing: :string,
    output: :string,
    viewport: :string,
    layout: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: @switches)
    cfg = resolve_opts(opts, paths)
    url = resolve_view(cfg.view)

    File.rm_rf!(Path.join(@workspace, "videos"))
    File.mkdir_p!(Path.join(@workspace, "videos"))
    File.rm(@cast)

    env = [
      {"CMS_DEMO_SESSION", cfg.session},
      {"CMS_DEMO_URL", url},
      {"CMS_DEMO_FROM", to_string(cfg.from)},
      {"CMS_DEMO_TO", to_string(cfg.to || "")},
      {"CMS_DEMO_DELAY", to_string(cfg.delay)},
      {"CMS_DEMO_PACING", cfg.pacing},
      {"CMS_DEMO_VIEWPORT", cfg.viewport},
      {"CMS_DEMO_VIDEO_DIR", Path.join(@workspace, "videos")},
      {"CMS_DEMO_CAST", @cast}
    ]

    Mix.shell().info("▶ recording (view=#{cfg.view} from=#{cfg.from} to=#{cfg.to || "end"})")
    sh!("node", ["record.js"], cd: @workspace, env: env)

    Mix.shell().info("▶ terminal cast → mp4")
    File.rm(Path.join("/tmp", "terminal.gif"))
    # Bump terminal font so it stays readable when letterboxed into 1080p.
    sh!("agg", ["--font-size", "18", @cast, "/tmp/terminal.gif"])
    # Force 30 fps CFR — agg→gif inherits the cast's variable timing, which
    # xfade refuses to chain across. CFR makes scenes assemble-able.
    sh!("ffmpeg", [
      "-y",
      "-i",
      "/tmp/terminal.gif",
      "-pix_fmt",
      "yuv420p",
      "-vf",
      "fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2",
      "-vsync",
      "cfr",
      @terminal_mp4
    ])

    Mix.shell().info("▶ browser webm → mp4")
    [webm | _] = Path.wildcard(Path.join(@workspace, "videos/*.webm"))

    sh!("ffmpeg", [
      "-y",
      "-i",
      webm,
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-vf",
      "fps=30",
      "-vsync",
      "cfr",
      @browser_mp4
    ])

    filter = compose_filter(cfg.layout)
    Mix.shell().info("▶ compose (layout=#{cfg.layout}) → 1080p 16:9 → #{cfg.output}")

    sh!("ffmpeg", [
      "-y",
      "-i",
      @terminal_mp4,
      "-i",
      @browser_mp4,
      "-filter_complex",
      filter,
      "-map",
      "[v]",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      "-shortest",
      cfg.output
    ])

    %{size: size} = File.stat!(cfg.output)
    Mix.shell().info("✓ #{cfg.output} (#{Float.round(size / 1024 / 1024, 2)} MB)")
  end

  defp resolve_opts(opts, paths) do
    session =
      List.first(paths) || Mix.raise("usage: mix demo.video SESSION_PATH [--view KEY ...]")

    %{
      session: session,
      view: opts[:view] || "stories",
      # Capture browser at native 1080p — it becomes the PiP composite
      # background, so the UI renders crisply with no upscaling.
      output: opts[:output] || "/tmp/demo.mp4",
      viewport: opts[:viewport] || "1920x1080",
      from: opts[:from] || 0,
      to: opts[:to],
      delay: opts[:delay] || 200,
      pacing: opts[:pacing] || "",
      layout: opts[:layout] || "pip"
    }
  end

  # Layout filters — all output a single `[v]` stream at 1920×1080.
  # Browser is input [1:v] (captured at native 1920×1080); terminal is [0:v].

  # pip: browser fills, terminal inset bottom-right. YouTube/large-screen ready.
  defp compose_filter("pip") do
    "[1:v]setsar=1[bg];" <>
      "[0:v]scale=540:-2:flags=lanczos,setsar=1[fg];" <>
      "[bg][fg]overlay=W-w-30:H-h-30:format=auto[v]"
  end

  # browser-only: terminal pane omitted entirely. Best for small hero embeds
  # where a tiny terminal inset would be unreadable.
  defp compose_filter("browser-only"), do: "[1:v]setsar=1[v]"

  # sxs: side-by-side at 720 height, scaled to 1920 wide, letterboxed to
  # 1920×1080. Preserves both panes' aspect; lots of black top/bottom.
  defp compose_filter("sxs") do
    "[0:v]scale=-2:720,setsar=1[t];" <>
      "[1:v]scale=-2:720,setsar=1[b];" <>
      "[t][b]hstack=inputs=2[hs];" <>
      "[hs]scale=1920:-2:flags=lanczos,pad=1920:1080:0:(1080-ih)/2:black[v]"
  end

  # vstack: terminal top, browser bottom. Each pane fills 1920 wide, 540 tall.
  # Cropped vertically to fit, so some browser chrome may be clipped.
  defp compose_filter("vstack") do
    "[0:v]scale=1920:-2,crop=1920:540:0:(ih-540)/2,setsar=1[t];" <>
      "[1:v]scale=1920:-2,crop=1920:540:0:(ih-540)/2,setsar=1[b];" <>
      "[t][b]vstack=inputs=2[v]"
  end

  defp compose_filter(other),
    do: Mix.raise("unknown --layout: #{inspect(other)} (pip | browser-only | sxs | vstack)")

  defp resolve_view("stories"), do: base_url() <> "/app/projects/market-my-spec/stories"
  defp resolve_view("graph"), do: base_url() <> "/app/projects/market-my-spec/requirements/graph"
  defp resolve_view("files"), do: base_url() <> "/app/projects/market-my-spec/files"
  defp resolve_view("issues"), do: base_url() <> "/app/projects/market-my-spec/issues"
  defp resolve_view("architecture"), do: base_url() <> "/app/projects/market-my-spec/architecture"

  defp resolve_view("three-amigos:" <> id),
    do: base_url() <> "/app/projects/market-my-spec/stories/#{id}/three-amigos"

  defp resolve_view("story:" <> id),
    do: base_url() <> "/app/projects/market-my-spec/stories/#{id}"

  defp resolve_view("http" <> _ = raw), do: raw
  defp resolve_view(other), do: Mix.raise("unknown --view: #{inspect(other)}")

  defp base_url, do: "http://localhost:4005"

  defp sh!(cmd, args, opts \\ []) do
    case System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts) do
      {_out, 0} ->
        :ok

      {out, code} ->
        IO.puts(out)
        Mix.raise("#{cmd} failed (exit #{code})")
    end
  end
end
