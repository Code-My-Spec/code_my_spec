defmodule CodeMySpec.Analysis.Fingerprint do
  @moduledoc """
  Computes an analyzer's input fingerprint from the File ledger.

  Each source hashes over the sorted `{path, fingerprint}` pairs of the File
  rows whose roles feed that analyzer. `files.fingerprint` is already SHA-256
  of content (stamped by FileSync), so this is a cheap hash-of-hashes — no
  file I/O. Callers must run `FileSync.sync_changed` first so fingerprints
  are current.

  `config/*.exs` is not in FileSync's `@sync_roots` and is deliberately
  excluded — config edits are rare in agent flows and don't invalidate runs.
  """

  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: ProjectFile
  alias CodeMySpec.Users.Scope

  # Which File roles feed each analyzer's inputs. `test_support` ships with
  # the test suite; `mix_exs` changes force full re-runs everywhere.
  @source_roles %{
    "compiler" => [:implementation, :test, :test_support, :mix_exs],
    "credo" => [:implementation, :test, :test_support, :mix_exs, :credo_exs],
    "exunit" => [:implementation, :test, :test_support, :mix_exs],
    "spex" => [:implementation, :test, :test_support, :bdd_spec, :mix_exs]
  }

  @doc "Roles that feed the given source."
  @spec roles(String.t()) :: [atom()]
  def roles(source), do: Map.fetch!(@source_roles, source)

  @doc """
  Current input fingerprint for every source, in one Files pass.

  Returns `%{source => fingerprint}`.
  """
  @spec current(Scope.t()) :: %{String.t() => String.t()}
  def current(%Scope{} = scope) do
    files = Files.list_files(scope)
    Map.new(@source_roles, fn {source, roles} -> {source, compute(files, roles)} end)
  end

  @doc "Current input fingerprint for one source."
  @spec current(Scope.t(), String.t()) :: String.t()
  def current(%Scope{} = scope, source) do
    scope
    |> Files.list_files()
    |> compute(roles(source))
  end

  @doc "Fingerprint a preloaded file list for one source's roles."
  @spec compute([ProjectFile.t()], [atom()]) :: String.t()
  def compute(files, roles) do
    role_set = MapSet.new(roles)

    files
    |> Enum.filter(&MapSet.member?(role_set, &1.role))
    |> Enum.map(&{&1.path, &1.fingerprint || ""})
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
