defmodule Mix.Tasks.Demo.Assemble do
  @shortdoc "Cross-fade a list of scene mp4s into one final demo video"

  @moduledoc """
  Assembles N scene mp4s (typically produced by `mix demo.video`) into one
  continuous mp4 with `ffmpeg xfade` transitions between them. The terminal
  pane reads as a continuous stream while the browser pane cross-fades from
  view to view — the "sped through the connective tissue and arrived at the
  next beat" effect.

      mix demo.assemble SCENE1.mp4 SCENE2.mp4 SCENE3.mp4 [options]

  ## Options

    * `--output PATH`     final mp4 (default: /tmp/demo_final.mp4)
    * `--transition NAME` xfade transition (default: fade — also: wipeleft,
                          slideleft, dissolve, smoothleft, circleopen, …)
    * `--duration SEC`    transition duration in seconds (default: 0.35)

  All scenes must be the same resolution + codec (`mix demo.video` produces
  matching output). Audio is dropped — voiceover is added in post.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  @switches [output: :string, transition: :string, duration: :float]

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: @switches)

    if paths == [] do
      Mix.raise("usage: mix demo.assemble SCENE1.mp4 SCENE2.mp4 [...] [--output PATH]")
    end

    output = opts[:output] || "/tmp/demo_final.mp4"

    if length(paths) == 1 do
      File.cp!(hd(paths), output)
      Mix.shell().info("✓ #{output} (single scene — copied)")
      :ok
    else
      transition = opts[:transition] || "fade"
      dur = opts[:duration] || 0.35

      Mix.shell().info("▶ normalizing #{length(paths)} scenes to 30fps (xfade requires CFR)")

      normalized =
        paths
        |> Enum.with_index()
        |> Enum.map(fn {p, i} ->
          out = "/tmp/demo_assemble_norm_#{i}.mp4"

          sh!("ffmpeg", [
            "-y", "-i", p,
            "-vf", "fps=30",
            "-vsync", "cfr",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            out
          ])

          out
        end)

      durations = Enum.map(normalized, &probe_duration!/1)

      Enum.zip(paths, durations)
      |> Enum.each(fn {p, d} -> Mix.shell().info("    #{Float.round(d, 2)}s  #{Path.basename(p)}") end)

      filter = build_xfade_filter(durations, transition, dur)
      last_label = "[v#{length(paths) - 1}]"

      total = Enum.sum(durations) - (length(paths) - 1) * dur

      Mix.shell().info(
        "▶ assembling (#{transition} #{dur}s) → #{output} (~#{Float.round(total, 1)}s)"
      )

      input_args = Enum.flat_map(normalized, fn p -> ["-i", p] end)

      ffmpeg_args =
        ["-y"] ++
          input_args ++
          [
            "-filter_complex",
            filter,
            "-map",
            last_label,
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            output
          ]

      case System.cmd("ffmpeg", ffmpeg_args, stderr_to_stdout: true) do
        {_out, 0} ->
          %{size: size} = File.stat!(output)
          Mix.shell().info("✓ #{output} (#{Float.round(size / 1024 / 1024, 2)} MB)")

        {out, code} ->
          IO.puts(out)
          Mix.raise("ffmpeg failed (exit #{code})")
      end
    end
  end

  defp probe_duration!(path) do
    case System.cmd(
           "ffprobe",
           [
             "-v",
             "error",
             "-show_entries",
             "format=duration",
             "-of",
             "default=noprint_wrappers=1:nokey=1",
             path
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Float.parse(String.trim(out)) do
          {d, _} -> d
          :error -> Mix.raise("could not parse duration for #{path}: #{out}")
        end

      {out, code} ->
        IO.puts(out)
        Mix.raise("ffprobe failed for #{path} (exit #{code})")
    end
  end

  # xfade chain: each transition's offset = sum(prior scene durations) - k*dur,
  # where k is the 1-based index of the transition. xfade eats `dur` seconds
  # of overlap per chained transition. Inputs are pre-normalized to 30fps CFR
  # by the caller — xfade refuses to chain mismatched / VFR streams.
  defp build_xfade_filter(durations, transition, dur) do
    durations
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Enum.reduce({[], "[0:v]"}, fn {_d, idx}, {acc, prev_label} ->
      offset =
        durations
        |> Enum.take(idx)
        |> Enum.sum()
        |> Kernel.-(idx * dur)
        |> Float.round(3)

      out_label = "[v#{idx}]"

      step =
        "#{prev_label}[#{idx}:v]xfade=transition=#{transition}:duration=#{dur}:offset=#{offset}#{out_label}"

      {[step | acc], out_label}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join(";")
  end

  defp sh!(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        IO.puts(out)
        Mix.raise("#{cmd} failed (exit #{code})")
    end
  end
end
