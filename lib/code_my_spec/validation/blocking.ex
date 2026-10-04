defmodule CodeMySpec.Validation.Blocking do
  @moduledoc """
  Which problems may block, and which a gate enforces.

  A leaf beneath Validation, Promotion and Analysis (John, 2026-09-27: reads
  move down). The stop, promotion and the analysis digest all read this one
  definition, so they cannot disagree about the same finding (b5fa5856,
  4a4cb998), and none of them depends on another to get it.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.BddSpecs,
      CodeMySpec.Configurations,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  # Spex enforcement is per-story, and it runs BEFORE the configured mode
  # rather than as another mode. A story that has never gone green is
  # *supposed* to be red — its specs are the contract driving the
  # implementation that hasn't been written yet. Blocking on that is what
  # kept `ProjectConfiguration.spex` pinned at `:off`.
  #
  # Demoted problems stay advisory rather than being dropped: the failure
  # is still real and still belongs on the Problems page, it just isn't
  # the agent's problem yet.
  #
  # Every other source is story-agnostic and passes through untouched.
  # The criterion says which story it belongs to. The filename does not.
  #
  # This read the leading number out of `test/spex/<n>_.../` and treated it as a
  # story id. Those numbers are directory names and have drifted from the ids:
  # measured on this project, `811_user_sees_the_agents_task_queue_at_a_glance`
  # derives 811 — a real story, "Onboarding lives at /app", `specs_ready` false
  # — while the story with that title is 862, `specs_ready` true. So a latched
  # story gated nothing (no path derives 862) and an unlatched one gated spex
  # that were not its own.
  #
  # Both wrong answers are silent, because a number that resolves to *a* story
  # looks exactly like one that resolves to the right story. A missing story
  # would have hit the `nil` branch and been loud.
  #
  # `criteria.spec_path` is the recorded answer — `claim_spec_paths/3` writes it
  # when a spex file is created, which is why it survives a rename. 22 of this
  # project's 25 spex problems join on it exactly.
  #
  # The filename parse stays as the fallback for a spex no criterion claims.
  #
  # An orphan blocks. That was an open question here — "there is no right answer
  # for an orphan" — and it is settled: block *because* it is orphaned. The
  # argument for the other side is that an unlatched spex should not block, and
  # an orphan is unlatched by definition; the argument against, which wins, is
  # that a spex whose story link has broken would then go quiet instead of loud,
  # and a real regression could hide behind it. A broken link should surface as
  # a block, not as silence.
  #
  # That fallback now resolves what it parses. The directory name is the story's
  # durable **number**, and it used to be handed straight to a set of primary
  # keys — the comparison above, made from the wrong end. Going through
  # `story_ids_by_number` means an unmatched number answers `nil` and lands in
  # the loud branch instead of quietly naming whichever story holds that id.
  @doc """
  Whether `problem` may block anything: promotion, task evaluation, the stop
  hook, the digest an analyzer run sends. The one definition, so those cannot
  disagree about the same finding again (b5fa5856, 4a4cb998).

  An advisory finding (`:info` — low-priority credo, low sobelow) blocks only
  when the project's `advisory_findings` setting is `:block`; it is
  `:dont_block` by default (John, 2026-10-04). Everything else may block, and
  whether it does is then the caller's rule (mode, latch, attribution).
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

  Public so `Hooks.AnalysisAlert` can count the same population the gate blocks
  on rather than everything recorded. Reused rather than reimplemented, because
  two copies of "what counts as enforceable" drift, and the drift is silent —
  the alert would report a number the gate disagrees with and nobody would see
  which was wrong.

  Costs three reads, so it is only worth calling once something has landed. The
  alert's silent path never reaches here.
  """
  @spec enforceable(Scope.t(), [Problems.Problem.t()]) :: [Problems.Problem.t()]
  def enforceable(%Scope{} = scope, problems) do
    ctx = %{
      specs_ready_story_ids: specs_ready_story_ids(scope),
      criterion_story_ids: AcceptanceCriteria.spec_path_story_ids(scope),
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

  def split_by_story_enforcement("spex", problems, ctx) do
    %{
      specs_ready_story_ids: ready_ids,
      criterion_story_ids: by_path,
      spec_file_story_ids: by_spec_file,
      story_ids_by_number: by_number
    } = ctx

    Enum.split_with(problems, fn problem ->
      located?(problem) and
        case story_id_for(problem.file_path, by_path, by_spec_file, by_number) do
          nil -> true
          story_id -> MapSet.member?(ready_ids, story_id)
        end
    end)
  end

  def split_by_story_enforcement(_source, problems, _ctx), do: {problems, []}

  # A finding the runner could not place is not an orphan: it has no story
  # link to have broken. sexy_spex 0.2.1's `fail_on_error_logs` failure carries
  # no stacktrace or spec file, the reconciler stores "unknown", and 24 of them
  # refused metric_flow's QA agent every turn (d91436b7). Advisory, not silent.
  defp located?(%{file_path: path}), do: is_binary(path) and path != "unknown"

  # Assignment does NOT exempt a spex finding, and criterion 2406 is why.
  #
  # This used to also require the story to be assigned to this checkout, on the
  # same reasoning `issues_resolved` uses: a gate whose passing state depends on
  # work outside the gated unit is a wall, and an agent on the war-epic copy was
  # shown 21 findings from an epic assigned to the main checkout.
  #
  # But `specs_ready` already answers that. The latch is *earned* — set when a
  # story's specs have gone green — so a finding that survives it is a
  # regression on proven behaviour, not somebody else's unfinished work. 2406
  # states the consequence directly: "an exemption this wide would let a broken
  # build through on every checkout that did not happen to own it."
  #
  # So the two guards are not both needed, and only one is right. Unready
  # stories are held back by the latch, which is what stopped those 21 findings;
  # ready ones block whoever is stopping, wherever they are assigned.

  # Criteria first, then the file row, then the directory name.
  #
  # The last of those is a guess and was doing most of the work. Spex
  # directories are named from `story.number` in some projects and `story.id` in
  # others, so `derive_story_number/1` hands back an id where a number is
  # expected, the lookup misses, and the problem lands in the `nil` branch —
  # which enforces. An unwritten feature's red spec then blocks a stop as though
  # it were a regression, and the agent is shown a backlog with no owner.
  #
  # Broken Oaths on 2026-09-08: 38 of 54 directories id-named, and 90 of 145
  # spex problems enforced this way over features nobody had written yet.
  #
  # `files.story_id` is resolved at sync time from the spec itself and was
  # correct for every directory of both conventions, so it goes ahead of the
  # parse. The parse stays last rather than being deleted: a spec file that has
  # not been synced yet has no row, and a directory name is better than nothing
  # there.
  def story_id_for(file_path, by_path, by_spec_file, by_number) do
    Map.get(by_path, file_path) ||
      Map.get(by_spec_file, file_path) ||
      story_id_from_path(file_path, by_number) ||
      story_id_from_directory(file_path, by_path)
  end

  # A legacy spex directory names no story number, and a file in it whose
  # criterion was renumbered is recorded against nothing. Unattributed, its
  # failure blocked regardless of the story's `specs_ready` — metric_flow's
  # unbuilt white-label and auto-enrollment spex held every promote on
  # 2026-09-27. The directory's story is the one every recorded spec in it
  # belongs to; a mixed directory answers nothing.
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
