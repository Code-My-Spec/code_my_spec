defmodule CodeMySpec.McpServers.Requirements.Tools.RefreshEmbeddings do
  @moduledoc """
  Re-embed the project so `semantic_search` sees today's code.

  Split out of `sync_project`, which used to do this as a pre-pass. On this
  project that pass took **1,700,691ms** — twenty-eight minutes, against 27
  seconds of actual file work — because it re-embeds the framework knowledge
  corpus, re-projects hex docs from `deps/`, and embeds every changed file.
  Model inference is simply slow, and no amount of tuning makes that a
  reasonable thing to do while an MCP client waits.

  Nothing about the requirement graph depends on it. Files, components and
  every requirement check read the database, which `sync_project` keeps
  current in well under a second. Embeddings serve `semantic_search` and
  nothing else, so being minutes behind costs a slightly stale search and
  nothing more.

  Which is why this is a tool rather than a step: the caller decides whether it
  is worth the wait, and says so by name.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:wait, :boolean,
      required: false,
      description:
        "Block until embedding finishes. Off by default — a full refresh can take tens of " <>
          "minutes and will exceed most client timeouts."
    )
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> refresh(scope, Map.get(params, :wait, false), frame)
      {:error, reason} -> {:reply, Response.tool() |> Response.error("#{reason}"), frame}
    end
  end

  defp refresh(%{cwd: nil}, _wait, frame) do
    text = """
    Nothing to embed from here — this server holds no working copy.

    The harness owns the files. Run this where the working copy is.
    """

    {:reply, Response.tool() |> Response.text(text), frame}
  end

  defp refresh(scope, true, frame) do
    case FileSync.sync(scope, base_dir: scope.cwd, embed: true) do
      {:ok, result} ->
        text = """
        # Embeddings Refreshed

        - Files: #{result.total_files} (#{length(result.changed_paths)} re-embedded)

        `semantic_search` is current.
        """

        {:reply, Response.tool() |> Response.text(text), frame}

      # This used to be a bang match on the stated grounds that sync "answers
      # `{:ok, _}` or raises". It does neither now: an environment that cannot
      # walk a working copy says so, because the alternative it used to take was
      # treating "I saw nothing" as "there is nothing" and deleting the lot.
      {:error, reason} ->
        text = """
        # Nothing Refreshed

        This scope has no working copy to walk (#{inspect(reason)}), so nothing was \
        scanned and no embeddings changed. `semantic_search` still answers from what \
        was last recorded.

        The harness owns the files. Run this where the working copy is.
        """

        {:reply, Response.tool() |> Response.text(text), frame}
    end
  end

  defp refresh(scope, _wait, frame) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      FileSync.sync(scope, base_dir: scope.cwd, embed: true)
    end)

    text = """
    # Embedding Started

    Running in the background — expect minutes, not seconds, on a project of \
    any size. `semantic_search` will catch up as it goes.

    Nothing else waits on this: the requirement graph reads the database, which \
    `sync_project` already brought current.
    """

    {:reply, Response.tool() |> Response.text(text), frame}
  end
end
