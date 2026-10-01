defmodule CodeMySpec.Problems do
  @moduledoc """
  A unified abstraction for problems, warnings, and errors discovered across
  different analysis tools and validation processes. Normalizes heterogeneous
  tool outputs into a consistent data model that can be used both ephemerally
  (in-memory during sessions) and persistently (stored for project-level fitness tracking).
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.Files,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Tests,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Files
  alias CodeMySpec.Problems.{ProblemConverter, ProblemRenderer, ProblemRepository}
  alias CodeMySpec.Requirements.GraphInputs

  # Repository functions
  defdelegate list_project_problems(scope, opts \\ []), to: ProblemRepository
  defdelegate watermark(scope), to: ProblemRepository
  defdelegate list_problems_paginated(scope, opts \\ []), to: ProblemRepository
  defdelegate component_ids_with_problems(scope), to: ProblemRepository

  # Writes. One requirement still reads findings: `bdd_specs_passing`, from the
  # spex source (28d72f8a — no component requirement reads problems any more,
  # and they are out of every fingerprint). So a write announces
  # `problems_changed` only when it can have moved spex; the per-source writers
  # below know their source and stay quiet for compiler, credo and exunit.
  # Wrapped rather than delegated for that one line; there is no single choke
  # point underneath.

  # The deleters count the rows they removed, so `{:ok, 0}` is proof that
  # nothing moved and announcing it would be a lie the fingerprint then has to
  # disprove. A clean sync calls `clear_problems_for_missing_files/2` every
  # time and deletes nothing almost every time.

  def create_problems(scope, problems),
    do: scope |> ProblemRepository.create_problems(problems) |> announce_if_moved(scope)

  def clear_project_problems(scope),
    do: scope |> ProblemRepository.clear_project_problems() |> announce_if_moved(scope)

  def delete_problems_for_components(scope, component_ids),
    do:
      scope
      |> ProblemRepository.delete_problems_for_components(component_ids)
      |> announce_if_moved(scope)

  # The files are still on disk — this clears one analyzer's findings at paths
  # that remain — so their owners resolve and the mark can name them.
  def clear_problems_for_source(scope, source_filter, file_paths) do
    result = ProblemRepository.clear_problems_for_source(scope, source_filter, file_paths)

    if spex?(source_filter[:source]),
      do: announce_if_moved(result, scope, Files.owners_of_paths(scope, file_paths)),
      else: result
  end

  def clear_problems_for_missing_files(scope, current_paths),
    do:
      scope
      |> ProblemRepository.clear_problems_for_missing_files(current_paths)
      |> announce_if_moved(scope)

  # The replacers answer with what they inserted and say nothing about what
  # they deleted, so an empty answer is not a no-op: an analyzer reporting a
  # source it has just cleaned drops every row for it and returns `{:ok, []}`,
  # and that is precisely the change that unblocks somebody. These announce on
  # any success and let the fingerprint decide, which is the direction
  # `GraphInputs` picks everywhere — a publish that moved nothing costs a hash.

  def replace_project_problems(scope, problems),
    do: scope |> ProblemRepository.replace_project_problems(problems) |> announce(scope)

  def replace_problems_for_files(scope, file_paths, problems),
    do:
      scope
      |> ProblemRepository.replace_problems_for_files(file_paths, problems)
      |> announce(scope, Files.owners_of_paths(scope, file_paths))

  # The one problem writer that already knows which components it touched, and
  # the one most worth telling. `Freshness.component/2` hashes
  # `problem_digests_by_component`, and an analyzer writes here on every agent
  # turn — so this is the input that most often takes the whole project stale
  # for a change that belonged to a handful of modules.
  def replace_problems_for_components(scope, component_ids, source, problems) do
    result =
      ProblemRepository.replace_problems_for_components(scope, component_ids, source, problems)

    if spex?(source),
      do: announce(result, scope, Enum.map(component_ids, &{"component", &1})),
      else: result
  end

  def reconcile_problems_for_source(scope, source, file_scope, problems) do
    result = ProblemRepository.reconcile_problems_for_source(scope, source, file_scope, problems)
    if spex?(source), do: announce(result, scope), else: result
  end

  # A filter that names no source could have touched spex.
  defp spex?(nil), do: true
  defp spex?(source), do: source in ["spex", :spex]

  defp announce_if_moved(result, scope), do: announce_if_moved(result, scope, [])

  defp announce_if_moved({:ok, 0} = result, _scope, _entities), do: result
  defp announce_if_moved({:ok, []} = result, _scope, _entities), do: result
  defp announce_if_moved(result, scope, entities), do: announce(result, scope, entities)

  # What is left un-narrowed, and why.
  #
  # `clear_problems_for_missing_files/2` is handed the paths that *remain*, so
  # the components it actually affects are the ones whose files are gone — the
  # same shape that stops `FileSync` naming anything on a removal.
  # `reconcile_problems_for_source/4` takes a file scope rather than a path
  # list. `replace_project_problems/2` writes rows with no component, and
  # whether any requirement reads those is not something this narrowing
  # established — naming `:project` would be a guess in the under-invalidating
  # direction.
  #
  # All three record `:unknown` and recompute everything, which is correct and
  # expensive, and is the honest state to leave them in.
  defp announce(result, scope), do: announce(result, scope, [])

  defp announce({:ok, _moved} = result, scope, entities) do
    # The event as well as the marks. `bdd_specs_passing` is settled from it
    # (`Handlers`, the `:specs` profile), and the entities beside it are the
    # fallback for anything without a handler.
    # Findings come from an analyzer run on one tree, so they are that
    # checkout's problems.
    GraphInputs.event(scope, "Problems", "problems_changed", %{}, entities, :this_checkout)
    result
  end

  defp announce(result, _scope, _entities), do: result

  # Converter functions
  defdelegate from_credo(credo_data), to: ProblemConverter
  defdelegate from_compiler(compiler_data), to: ProblemConverter
  defdelegate from_test_failure(test_error), to: ProblemConverter

  # Renderer functions
  defdelegate render_stop_response(blocking, advisory, opts \\ []), to: ProblemRenderer
  defdelegate advisory_assignment_note(advisory, assignment), to: ProblemRenderer
  defdelegate truncate_to_cap(text, opts \\ []), to: ProblemRenderer
end
