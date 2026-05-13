defmodule CodeMySpec.ProjectSync.Sync do
  @moduledoc """
  Orchestrates a single-path filesystem-to-DB sync.

  Decouples "a relevant file changed" from "what triggered the event."
  Production code reaches here through `FileWatcherServer` after an OS
  `:file_event` arrives; specs reach here directly with a memfs scope.
  Both call paths run the same orchestration so the projection contract
  is exercised identically.

  Side effects per call, in order:

    1. `FileSync.sync_path/3` — upsert/delete the File row, refresh
       fingerprint, run embeddings hooks.
    2. `FileComponentSync.sync_from_files/2` — re-derive the owning
       component when the path's role is component-relevant.
    3. `Phoenix.PubSub` broadcast on `"project:<id>:watcher"` so
       LiveViews can render watcher activity in real time.
  """

  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Users.Scope

  require Logger

  @pubsub CodeMySpec.PubSub

  @doc """
  Sync a single absolute path. Same orchestration the file watcher
  invokes from an OS file event; safe to call directly from specs or
  any caller that has a scoped trigger.

  Returns `{:ok, result}` where `result.changed_path` is the relative
  path that was upserted/deleted (nil if the path was ignored by
  classification), or `{:error, reason}` on rescue.
  """
  @spec sync_path(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sync_path(%Scope{} = scope, abs_path) when is_binary(abs_path) do
    project_root = scope.cwd

    try do
      {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: project_root)

      if result.changed_path && component_relevant_path?(result.changed_path) do
        FileComponentSync.sync_from_files(scope,
          base_dir: project_root,
          changed_paths: [result.changed_path]
        )
      end

      maybe_broadcast(scope, result)
      {:ok, result}
    rescue
      e ->
        Logger.error("[Sync] Error processing #{abs_path}: #{Exception.message(e)}")
        {:error, e}
    end
  end

  @doc """
  Subscribe the calling process to watcher activity for the given
  project. LiveViews call this in `mount` (or `handle_params` once a
  project is known) so they can update on incoming `:watcher_synced`
  messages.

  Returns `:ok` when subscribed, `:ignored` when no project is active.
  """
  @spec subscribe(Scope.t()) :: :ok | :ignored
  def subscribe(%Scope{active_project: nil}), do: :ignored

  def subscribe(%Scope{active_project: %{id: project_id}}) do
    Phoenix.PubSub.subscribe(@pubsub, topic(project_id))
  end

  @doc false
  def topic(project_id), do: "project:#{project_id}:watcher"

  defp maybe_broadcast(_scope, %{changed_path: nil}), do: :ok

  defp maybe_broadcast(%Scope{active_project: %{id: project_id}}, %{changed_path: path}) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(project_id),
      {:watcher_synced, %{path: path, at: DateTime.utc_now()}}
    )
  end

  defp maybe_broadcast(_scope, _result), do: :ok

  defp component_relevant_path?(rel_path) do
    String.starts_with?(rel_path, "lib/") or
      String.starts_with?(rel_path, "test/") or
      String.starts_with?(rel_path, ".code_my_spec/spec/")
  end
end
