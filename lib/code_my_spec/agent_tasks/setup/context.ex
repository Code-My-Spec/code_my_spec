defmodule CodeMySpec.AgentTasks.Setup.Context do
  @moduledoc """
  Loads the persisted view of every setup-relevant file from the DB so that
  `Setup.*` step `check/1` calls can decide pass/fail with O(1) map lookups
  instead of touching the filesystem on every requirements graph render.

  Files are populated by `FileSync` (with role-specific validators that
  write per-concern keys into `validation_errors`). Step `check/1` decodes
  those keys.
  """

  import Ecto.Query

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @setup_roles [
    :mix_exs,
    :credo_exs,
    :claude_md,
    :setup_config,
    :test_support,
    :agents_md,
    :rule
  ]

  @type t :: %__MODULE__{
          files_by_path: %{String.t() => FileRecord.t()},
          files_by_role: %{atom() => [FileRecord.t()]},
          environment: term() | nil,
          project_id: Ecto.UUID.t() | nil
        }

  defstruct files_by_path: %{}, files_by_role: %{}, environment: nil, project_id: nil

  @doc """
  Load setup-relevant File records for the project.

  Also stashes `scope.environment` so `dir_status/2` can stat a directory when
  there is a disk — directories aren't synced, so they are the one thing not
  answerable from File records alone. It is nil on the light harness, which
  `dir_status/2` treats as "cannot tell" rather than "not there".
  """
  @spec load(Scope.t()) :: t()
  def load(%Scope{active_project_id: nil} = scope) do
    %__MODULE__{environment: scope.environment, project_id: nil}
  end

  def load(%Scope{active_project_id: project_id} = scope) do
    files =
      FileRecord
      |> where([f], f.project_id == ^project_id and f.role in ^@setup_roles)
      |> scope_to_working_copy(scope)
      |> Repo.all()

    %__MODULE__{
      files_by_path: Map.new(files, &{&1.path, &1}),
      files_by_role: Enum.group_by(files, & &1.role),
      environment: scope.environment,
      project_id: project_id
    }
  end

  # One checkout's files, not every checkout's.
  #
  # This used to load by project alone and key the result by path with
  # `Map.new/2`, which keeps the last of any duplicate — and every checkout of a
  # project contributes its own `mix.exs`. Two of this project's working copies
  # are *different applications* registered against it (QA fixtures), so
  # `app_name/1` answered `qa_sandbox` for `code_my_spec` and
  # `spex_boundary_ready` went looking for `qa_sandbox_spex_fixtures.ex` on a
  # project with 1137 spex already passing. Which row won was decided by row
  # order, so it could change on any sync. Issue `282428a3`.
  #
  # Every caller is a setup checker asking whether *this checkout* is configured
  # — its mix.exs, its credo checks, its test support — so the working copy is
  # the right grain, and it is the grain `Files.list_files/1` already uses for
  # exactly this reason: "one present in one checkout and absent in another
  # reads as present".
  #
  # No working copy in scope leaves the query as it was. A scope with no
  # checkout is a mix task or the web UI, and narrowing to a copy it does not
  # have would answer "nothing is set up" rather than "I cannot tell".
  defp scope_to_working_copy(query, %Scope{active_working_copy_id: nil}), do: query

  defp scope_to_working_copy(query, %Scope{active_working_copy_id: working_copy_id}),
    do: where(query, [f], f.working_copy_id == ^working_copy_id)

  @doc """
  Look up a File record by path. Returns nil if not synced.
  """
  @spec file(t(), String.t()) :: FileRecord.t() | nil
  def file(%__MODULE__{files_by_path: by_path}, path), do: Map.get(by_path, path)

  @doc """
  Return all File records with the given role.
  """
  @spec files_with_role(t(), atom()) :: [FileRecord.t()]
  def files_with_role(%__MODULE__{files_by_role: by_role}, role),
    do: Map.get(by_role, role, [])

  @doc """
  Read the per-concern error from a File's validation_errors.

  Returns `nil` if the concern passed, an error string if it failed, or
  the `missing_msg` if the file isn't in the DB at all (not synced yet).
  """
  @spec error(t(), String.t(), String.t() | atom(), String.t()) :: nil | String.t()
  def error(ctx, path, key, missing_msg) do
    case file(ctx, path) do
      nil -> missing_msg
      %FileRecord{validation_errors: nil} -> missing_msg
      %FileRecord{validation_errors: errors} -> Map.get(get_errors(errors), to_string(key))
    end
  end

  @doc """
  Read a `data` field from a File's validation_errors.
  """
  @spec data(t(), String.t(), String.t() | atom()) :: any() | nil
  def data(ctx, path, key) do
    case file(ctx, path) do
      nil -> nil
      %FileRecord{validation_errors: nil} -> nil
      %FileRecord{validation_errors: errors} -> Map.get(get_data(errors), to_string(key))
    end
  end

  @doc """
  Returns the app name extracted from mix.exs at sync time, or nil if mix.exs
  isn't synced or couldn't be parsed.
  """
  @spec app_name(t()) :: String.t() | nil
  def app_name(ctx), do: data(ctx, "mix.exs", :app_name)

  @doc """
  Whether a directory is there, when that can be determined at all.

  Three states rather than two, because on the light harness there is a real
  third one. The server has no disk — that is the whole design — so
  `scope.environment` is nil and there is nothing to stat. Answering `false` in
  that case is worse than not answering: it reports a directory as missing that
  may well exist, and no `mkdir` the agent runs can change the reply, because
  directories are not synced. That produced a requirement an agent could work at
  forever, and one did.

  What can still be known without a disk: a directory that holds a synced file
  exists. That is decided first and works everywhere, harness or local.

    * `:present`      — a synced file lives under it, or a stat found it
    * `:absent`       — there is a disk and it is not there
    * `:unobservable` — no disk, no synced file. Not evidence of absence.
  """
  @spec dir_status(t(), String.t()) :: :present | :absent | :unobservable
  def dir_status(%__MODULE__{} = ctx, path) do
    cond do
      holds_synced_file?(ctx, path) -> :present
      ctx.environment -> stat(ctx.environment, path)
      true -> :unobservable
    end
  end

  defp stat(env, path) do
    if Environments.file_exists?(env, path), do: :present, else: :absent
  end

  # Prefix match on the separator so `spec/foo` is not proven by `spec/foobar`.
  defp holds_synced_file?(%__MODULE__{files_by_path: by_path}, path) do
    prefix = String.trim_trailing(path, "/") <> "/"
    Enum.any?(by_path, fn {p, _} -> String.starts_with?(p, prefix) end)
  end

  defp get_errors(%{"errors" => e}) when is_map(e), do: e
  defp get_errors(_), do: %{}

  defp get_data(%{"data" => d}) when is_map(d), do: d
  defp get_data(_), do: %{}
end
