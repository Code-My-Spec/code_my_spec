defmodule CodeMySpec.Validation.Blocking do
  @moduledoc """
  Which problems may block, and which a gate enforces.

  A leaf beneath Validation, Promotion and Analysis: the stop, promotion and
  the analysis digest all read this one definition, so they cannot disagree
  about the same finding, and none depends on another to get it.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Stories,
      CodeMySpec.BddSpecs,
      CodeMySpec.Configurations,
      CodeMySpec.Files,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  Whether `problem` may block anything: promotion, task evaluation, the stop
  hook, the digest an analyzer run sends. The one definition, so those cannot
  disagree about the same finding.

  An advisory finding (`:info` — low-priority credo, low sobelow) blocks only
  when the project's `advisory_findings` setting is `:block`; it is
  `:dont_block` by default. Everything else may block, and whether it does is
  then the caller's rule (mode, attribution, role).
  """
  @spec can_block?(Problems.Problem.t() | map(), :block | :dont_block | nil) :: boolean()
  def can_block?(%{severity: :info}, advisory_findings), do: advisory_findings == :block
  def can_block?(_problem, _advisory_findings), do: true

  @doc "The project's `advisory_findings` setting, `:dont_block` when unset."
  @spec advisory_findings(Scope.t() | ProjectConfiguration.t() | nil) :: :block | :dont_block
  def advisory_findings(%ProjectConfiguration{advisory_findings: setting})
      when not is_nil(setting),
      do: setting

  def advisory_findings(%Scope{active_project_id: project_id} = scope)
      when is_binary(project_id),
      do: scope |> Configurations.get_or_create() |> advisory_findings()

  def advisory_findings(_scope_or_config), do: :dont_block

  @doc "`problems` that may block under this project's settings — `can_block?/2` over a list."
  @spec blockable(Scope.t() | nil, [Problems.Problem.t()]) :: [Problems.Problem.t()]
  def blockable(scope, problems) do
    setting = advisory_findings(scope)
    Enum.filter(problems, &can_block?(&1, setting))
  end

  @doc """
  The subset of `problems` this gate would actually enforce.

  Public so `Analysis.Alert`, `Promotion` and `Agents.Menu` count the same
  population the gate blocks on rather than everything recorded; two copies
  of "what counts as enforceable" drift silently.

  Costs three reads, so it is only worth calling once something has landed.
  """
  @spec enforceable(Scope.t(), [Problems.Problem.t()]) :: [Problems.Problem.t()]
  def enforceable(%Scope{} = scope, problems) do
    ctx = %{
      specs_ready_story_ids: specs_ready_story_ids(scope),
      criterion_story_ids: Files.bdd_spec_story_id_by_path(scope),
      spec_file_story_ids: Files.bdd_spec_story_id_by_path(scope),
      story_ids_by_number: Stories.list_story_ids_by_number(scope)
    }

    problems
    |> Enum.group_by(& &1.source)
    |> Enum.flat_map(fn {source, of_source} ->
      {enforced, _advisory} = split_by_story_enforcement(source, of_source, ctx)
      enforced
    end)
  end

  # Every located red spex blocks: analysis runs only at certify and promote,
  # so a red spex there is red whatever its story's latch. Only a finding with
  # no location is advisory (`located?/1`).
  def split_by_story_enforcement("spex", problems, _ctx),
    do: Enum.split_with(problems, &located?/1)

  def split_by_story_enforcement(_source, problems, _ctx), do: {problems, []}

  # A finding the runner could not place (no stacktrace or spec file; the
  # reconciler stores "unknown") is not an orphan — it has no story link to
  # have broken. Advisory, not silent.
  defp located?(%{file_path: path}), do: is_binary(path) and path != "unknown"

  # Criteria first, then the file row (resolved at sync time from the spec
  # itself), then the directory name parsed as a story number, then the
  # directory's common story. The parse stays for spec files not yet synced.
  # See knowledge/analysis, "Spex story attribution".
  def story_id_for(file_path, by_path, by_spec_file, by_number) do
    Map.get(by_path, file_path) ||
      Map.get(by_spec_file, file_path) ||
      story_id_from_path(file_path, by_number) ||
      story_id_from_directory(file_path, by_path)
  end

  # A legacy spex directory names no story number, and a file in it whose
  # criterion was renumbered is recorded against nothing. The directory's story
  # is the one every recorded spec in it belongs to; a mixed directory answers
  # nothing.
  defp story_id_from_directory(file_path, by_path) do
    dir = Path.dirname(file_path)

    case for({path, story_id} <- by_path, Path.dirname(path) == dir, uniq: true, do: story_id) do
      [story_id] -> story_id
      _ -> nil
    end
  end

  def story_id_from_path(file_path, by_number) do
    case Parser.derive_story_number(file_path) do
      nil -> nil
      number -> Map.get(by_number, number)
    end
  end

  def specs_ready_story_ids(scope) do
    scope
    |> Stories.list_specs_ready_story_ids()
    |> MapSet.new()
  end
end
