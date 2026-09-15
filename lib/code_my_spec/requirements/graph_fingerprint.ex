defmodule CodeMySpec.Requirements.GraphFingerprint do
  @moduledoc """
  Hashes everything the requirement graph is computed from.

  Same idea as `CodeMySpec.Analysis.Fingerprint`, which memoizes analyzer runs
  over `{path, fingerprint}` pairs — a hash of hashes, no file I/O. This one
  covers the wider input set `RequirementGraph` reads: files, components,
  stories, problem counts, analysis freshness, and configuration.

  ## Content, not timestamps

  Every field here is content-derived. Using `updated_at` would be simpler and
  would defeat the cache: `Files.upsert_files/2` replaces rows on conflict, so
  a sync that finds nothing changed still bumps every timestamp, and the
  fingerprint would differ on every pass.

  ## Direction of error

  A fingerprint that changes when it did not need to costs one recomputation.
  A fingerprint that stays the same when an input moved serves the agent stale
  instructions. So this leans toward over-invalidating: component and story
  digests carry whole structs rather than a hand-picked field list, because
  picking fields means guessing which ones the graph reads, and being wrong is
  silent.
  """

  alias CodeMySpec.Requirements.Preloader

  @doc """
  Fingerprint for a loaded preloader context and the project's configuration.

  Takes the context rather than a scope: the caller has already paid for the
  load, and hashing what was actually read is what makes this correct by
  construction rather than by a list of remembered dependencies.
  """
  @spec compute(Preloader.context(), struct() | map() | nil) :: String.t()
  def compute(ctx, config) do
    [
      {:code, code_version()},
      {:files, files_digest(ctx.files_by_project)},
      {:components, structs_digest(ctx.components, & &1.id)},
      {:stories, structs_digest(ctx.stories, & &1.id)},
      {:problems, problems_digest(ctx.problems_by_component)},
      {:config, struct_digest(config)},
      {:delegated, delegated_digest(ctx)}
    ]
    |> hash()
  end

  # `analysis_fresh` is deliberately absent, and the rule it follows is:
  # **changing files stales the graph; running analyzers freshens it.**
  #
  # As an input it did the opposite. The four booleans flip when an analyzer
  # *finishes*, so the completion of a run — the event that makes the graph more
  # trustworthy, not less — moved this fingerprint, missed the cache and
  # recomputed the project. Criterion 3448 measured that at the per-entity
  # grain (1116 of 1347 requirements, twice in an hour) and removed it there;
  # this is the same value one level up, keying `GraphCache`.
  #
  # It is not an input to begin with. Freshness is a qualifier on *serving* an
  # answer, which `RequirementGraph.serve/2` applies from the current context on
  # every read — downgrade-only and idempotent, so a cached graph is re-qualified
  # against today's freshness without being recomputed. What genuinely moves when
  # an analyzer lands is `problems`, one line above, and that stays.
  #
  # The residue: a checker that reads `ctx.analysis_fresh` at *compute* time
  # stores the qualifier instead of applying it, and nothing revisits that stored
  # answer. `SpecsPassingChecker` is the one that does.

  # The code that turns inputs into a graph is an input.
  #
  # Everything else here is what the graph is computed *from*. Nothing described
  # how it is computed, so the same inputs under changed code produced the same
  # fingerprint — and rows written by the old code read as current.
  #
  # That is not hypothetical. Scoping the file load to one working copy changed
  # the graph from 1,357 nodes to 2,783 on this project, and the cache row still
  # matched: `fetch/2` hit, and a reader was served a graph that predated the
  # fix. It surfaced only because the snapshot still carried a second copy of
  # the graph to compare the rows against — which it no longer does, so this
  # guard is now the only thing standing between a code change and a stale
  # graph served as current.
  #
  # The app version rather than a constant to bump by hand. It is coarser —
  # every release invalidates every project's snapshot, costing one recompute —
  # but the direction of error is the one already chosen throughout this module:
  # a fingerprint that changes when it need not costs CPU, and one that stays
  # the same when it should have moved serves an agent stale instructions.
  # Remembering to bump a constant is exactly the kind of step that gets missed
  # on the change that most needed it.
  defp code_version do
    case :application.get_key(:code_my_spec, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "unknown"
    end
  end

  # Rules, criteria, questions, personas and issues.
  #
  # These are what the `:delegate` requirements read — `three_amigos_complete`,
  # `personas_complete`, `issues_triaged`, `issues_resolved` — and until they
  # were here the fingerprint could not see them move. That is the gap that
  # made a published graph unsafe to serve to an agent: every input the *nodes*
  # read was covered, and the handful the *checkers* read was not, so a
  # three-amigos session could complete without the fingerprint noticing.
  #
  # Absent rather than empty when a context predates this field, so an older
  # cached graph reads as a miss instead of silently matching.
  defp delegated_digest(%{delegated_inputs: inputs}) when is_map(inputs) do
    inputs |> Map.to_list() |> Enum.sort()
  end

  defp delegated_digest(_ctx), do: :not_loaded

  # Files carry their own content hash already, so this is a hash of hashes.
  # `valid` and the owner ids ride along because the graph reads them directly
  # and they can change without the content changing — a component rename
  # relinks a file whose bytes never moved.
  defp files_digest(files) do
    files
    |> Enum.map(&{&1.path, &1.role, &1.fingerprint || "", &1.valid, &1.component_id, &1.story_id})
    |> Enum.sort()
  end

  defp problems_digest(problems_by_component) do
    problems_by_component
    |> Enum.flat_map(fn {component_id, by_source} ->
      Enum.map(by_source, fn {source, count} -> {component_id, source, count} end)
    end)
    |> Enum.sort()
  end

  defp structs_digest(structs, sort_key) do
    structs
    |> Enum.sort_by(sort_key)
    |> Enum.map(&struct_digest/1)
  end

  # Maps have no defined iteration order in the external term format, so a
  # struct is flattened to a key-sorted list before it reaches term_to_binary.
  # Associations are dropped: they are either not loaded (an unstable
  # `Ecto.Association.NotLoaded`) or a cycle. Timestamps are dropped for the
  # reason in the moduledoc.
  defp struct_digest(nil), do: nil

  defp struct_digest(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :inserted_at, :updated_at])
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Enum.map(fn
      {k, v} when is_list(v) -> {k, Enum.map(v, &assoc_id/1)}
      {k, v} -> {k, assoc_id(v)}
    end)
    |> Enum.sort()
  end

  defp struct_digest(map) when is_map(map), do: Enum.sort(Map.to_list(map))

  # Preloaded associations are summarized by id. Their own fields are either
  # irrelevant to the graph or covered by their own entry in the digest —
  # components are hashed in full separately, so hashing them again through a
  # parent's `dependencies` would only add cost.
  defp assoc_id(%_{id: id}), do: id
  defp assoc_id(other), do: other

  defp hash(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
