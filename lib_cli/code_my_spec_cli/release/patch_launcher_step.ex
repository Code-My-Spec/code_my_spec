defmodule CodeMySpecCli.Release.PatchLauncherStep do
  @moduledoc """
  Burrito build step that patches the Zig launcher to include "--" before user args.

  This prevents Elixir's start_cli from interpreting CLI arguments as script files.
  The "--" separator tells Elixir to stop processing options, so our application
  can receive the raw arguments via Burrito.Util.Args.argv().
  """

  @behaviour Burrito.Builder.Step

  @impl true
  def execute(%Burrito.Builder.Context{} = context) do
    IO.puts("\n[PatchLauncherStep] Patching Zig launcher to add -- separator...")

    # Find the erlang_launcher.zig file in Burrito deps
    burrito_path = context.self_dir
    launcher_path = Path.join([burrito_path, "src", "erlang_launcher.zig"])

    IO.puts("[PatchLauncherStep] Launcher path: #{launcher_path}")

    if File.exists?(launcher_path) do
      content = File.read!(launcher_path)

      # Check if already patched
      if String.contains?(content, "\"--\",  // Added by PatchLauncherStep") do
        IO.puts("[PatchLauncherStep] Already patched, skipping")
      else
        # Find the line with "-extra" and add "--" after it
        # Original:     "-extra",
        # Patched:      "-extra",
        #               "--",  // Added by PatchLauncherStep

        # Match the end of the erlang_cli array tolerant of line endings: the
        # zig source is checked out with CRLF on Windows, so a literal "\n"
        # pattern silently fails to match (leaving args unseparated). Capture the
        # whitespace/newline between "-extra", and the closing "};" and reuse it
        # so the inserted line keeps the file's existing line endings.
        patched_content =
          String.replace(
            content,
            ~r/"-extra",(\s*)\};/,
            ~s|"-extra",\\g{1}    "--",  // Added by PatchLauncherStep\\g{1}};|
          )

        if patched_content != content do
          File.write!(launcher_path, patched_content)
          IO.puts("[PatchLauncherStep] Successfully patched launcher")
        else
          IO.puts("[PatchLauncherStep] WARNING: Could not find pattern to patch")
          IO.puts("[PatchLauncherStep] Content around -extra:")

          # Show relevant section for debugging
          content
          |> String.split("\n")
          |> Enum.with_index()
          |> Enum.filter(fn {line, _} -> String.contains?(line, "-extra") end)
          |> Enum.each(fn {line, idx} ->
            IO.puts("  Line #{idx}: #{line}")
          end)
        end
      end
    else
      IO.puts("[PatchLauncherStep] WARNING: Launcher file not found at #{launcher_path}")
    end

    context
  end
end
