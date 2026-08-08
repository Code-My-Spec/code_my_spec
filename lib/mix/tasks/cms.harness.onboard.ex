defmodule Mix.Tasks.Cms.Harness.Onboard do
  @shortdoc "Point this working copy's agent hooks at its own harness id"

  @moduledoc """
  Address this checkout's hooks to the harness that serves it.

      mix cms.harness.onboard

  Reads the id the server issued this working copy and writes a plugin
  directory whose hooks post to `/api/harnesses/<id>/hooks/*` instead of the
  shared `/api/hooks/*`. Start the agent against that directory and every hook
  it fires says which checkout it came from.

  ## Why a generated directory

  The tracked plugin under `plugins/claude` has to stay generic: it is what the
  release packager ships, and a harness id baked into a published plugin would
  be one machine's identity handed to everyone who installs it. The tracked
  copy also cannot simply be edited in place — it is tracked, so an id written
  into it is an id committed, and a committed id is cloned into every checkout.
  That is the corruption the id exists to prevent.

  So this writes somewhere gitignored, per working copy, and leaves the shipped
  plugin alone.

  ## The id has to exist first

  It is issued by the server on the harness's first join for this checkout, and
  written to `.cms_harness_id`. If it is not there yet, the harness has not
  served this copy — start it (`just harness`, with this directory in
  `CMS_PROJECT_DIRS`) and run this again.
  """

  use Mix.Task

  alias CmsHarness.HarnessIdentity

  @plugin_source "plugins/claude"
  @plugin_dest ".claude/plugin-dev"

  @impl Mix.Task
  def run(args) do
    root = target_root(args)
    dest = Path.join(root, @plugin_dest)

    with {:ok, id} <- identity(root),
         :ok <- copy_plugin(root, dest),
         {:ok, count} <- address_hooks(dest, id),
         :ok <- address_mcp(dest, id) do
      report(id, dest, count, args)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  # Takes a path so one checkout can onboard another. A worktree on an older
  # branch does not have this task, and asking somebody to merge a branch
  # before they can be onboarded is a worse first experience than a positional
  # argument.
  defp target_root([path | _]) when is_binary(path), do: Path.expand(path)
  defp target_root(_), do: File.cwd!()

  defp identity(root) do
    case HarnessIdentity.read(root) do
      {:ok, id} ->
        {:ok, id}

      :none ->
        {:error,
         """
         No harness id for #{root}.

         The server issues it on the harness's first join for this checkout. Add
         this directory to CMS_PROJECT_DIRS, start the harness, wait for it to
         connect, then run this again.
         """}

      {:error, reason} ->
        {:error, "Could not read #{HarnessIdentity.path(root)}: #{inspect(reason)}"}
    end
  end

  defp copy_plugin(root, dest) do
    source = Path.join(root, @plugin_source)

    if File.dir?(source) do
      File.rm_rf!(dest)
      File.mkdir_p!(Path.dirname(dest))
      File.cp_r!(source, dest)
      :ok
    else
      {:error, "No #{@plugin_source} at #{source} — run this from a checkout root."}
    end
  end

  # Only the hook paths move. The port, the headers and the payload are the
  # shipped plugin's and stay as they are, so the generated copy differs from
  # what users run in exactly one respect.
  defp address_hooks(dest, id) do
    file = Path.join([dest, "hooks", "hooks.json"])

    case File.read(file) do
      {:ok, contents} ->
        File.write!(file, String.replace(contents, "/api/hooks/", "/api/harnesses/#{id}/hooks/"))

        {:ok, contents |> String.split("/api/hooks/") |> length() |> Kernel.-(1)}

      {:error, reason} ->
        {:error, "Could not read #{file}: #{inspect(reason)}"}
    end
  end

  # The MCP surface has the same question to answer as the hooks — which
  # working copy is this? — so it gets the same answer. Left on `?dir=` it
  # would be the one place a directory still decided something, and two
  # checkouts of one project would share an MCP session.
  defp address_mcp(dest, id) do
    file = Path.join([dest, ".claude-plugin", "plugin.json"])

    case File.read(file) do
      {:ok, contents} ->
        addressed =
          String.replace(contents, "/mcp?dir=${CLAUDE_PROJECT_DIR}", "/mcp?harness=#{id}")

        File.write!(file, addressed)
        :ok

      {:error, reason} ->
        {:error, "Could not read #{file}: #{inspect(reason)}"}
    end
  end

  defp report(id, dest, count, _args) do
    Mix.shell().info("""

    Harness id:  #{id}
    Plugin dir:  #{dest}
    Addressed:   #{count} hook endpoint(s)

    Start the agent against it:

        claude --plugin-dir #{dest}

    Every hook now names this working copy. A hook naming an id the harness
    does not serve is refused rather than resolved to a neighbouring checkout.
    """)
  end
end
