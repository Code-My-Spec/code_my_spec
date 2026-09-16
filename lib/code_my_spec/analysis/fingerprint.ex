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

  # Every role, split once into "code the Elixir toolchain reads" and
  # "documents". Sources are then composed from `@code_roles` rather than
  # each listing its own inputs from memory.
  #
  # The split is the point. Listing inputs per source is an allow-list, and an
  # allow-list that falls short fails *silently*: the source keeps reporting
  # fresh while holding findings about content that has since changed, and the
  # stop hook drops the staleness marker that would have said so. That is
  # `b1340e13` — credo's set omitted `:bdd_spec`, so editing a `_spex.exs`
  # could not move credo's fingerprint, and five already-fixed findings were
  # presented as current. `:credo_check` was the same bug unfired: those are
  # Elixir modules credo *loads*, so editing a check changes its verdicts, and
  # nothing invalidated credo.
  #
  # Splitting every role forces the decision to be made once, in the open, and
  # `FingerprintRolesTest` fails if a new role is added to neither list. The
  # residual failure mode is over-invalidation — a needless re-run — which
  # costs time and never lies.
  @code_roles [
    :implementation,
    :test,
    :test_support,
    :bdd_spec,
    :credo_check,
    :mix_exs,
    :credo_exs
  ]

  # Not read by any analyzer: markdown, JSON, persona and QA artifacts, and the
  # knowledge corpora. `:integration` and `:qa_script` look like code and are
  # not — the scanner files them under document directories.
  @document_roles [
    :spec,
    :rule,
    :json,
    :review,
    :qa_brief,
    :qa_result,
    :qa_plan,
    :qa_script,
    :config,
    :architecture,
    :persona_summary,
    :persona_sources,
    :integration,
    :task_artifact,
    :claude_md,
    :agents_md,
    :setup_config,
    :knowledge,
    :project_knowledge,
    :hex_doc,
    :deploy_artifact,
    :encrypted_env
  ]

  @doc "Roles holding code an analyzer reads."
  @spec code_roles() :: [atom()]
  def code_roles, do: @code_roles

  @doc "Roles no analyzer reads."
  @spec document_roles() :: [atom()]
  def document_roles, do: @document_roles

  # `mix compile` and `mix test` do not read `*_spex.exs` — those are a
  # separate task with its own pattern, which `spex` covers — and neither cares
  # about `.credo.exs` or credo's own checks.
  @toolchain_only @code_roles -- [:bdd_spec, :credo_check, :credo_exs]

  @source_roles %{
    "compiler" => @toolchain_only,
    "credo" => @code_roles,
    "exunit" => @toolchain_only,
    "spex" => @code_roles -- [:credo_check, :credo_exs]
  }

  # The inverse of `@source_roles`, built once at compile time.
  #
  # Every reader so far has asked "which files does this source read"; an event
  # asks the other way — a file with this role changed, whose results does that
  # invalidate. Deriving it rather than writing a second table is the point:
  # two hand-maintained directions of one mapping is the shape that drifts, and
  # the drift here is a source that stays "fresh" over code it never saw.
  @sources_by_role @source_roles
                   |> Enum.flat_map(fn {source, roles} -> Enum.map(roles, &{&1, source}) end)
                   |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  @doc """
  Which analyzer sources a file in this role invalidates.

  `[]` for a role no analyzer reads — a persona summary, a knowledge doc — which
  is why a document changing has never made anything stale and should not start.
  """
  @spec sources_for_role(atom()) :: [String.t()]
  def sources_for_role(role), do: Map.get(@sources_by_role, role, [])

  @doc "Which sources any of these roles invalidate."
  @spec sources_for_roles(Enumerable.t()) :: [String.t()]
  def sources_for_roles(roles),
    do: roles |> Enum.flat_map(&sources_for_role/1) |> Enum.uniq()

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
