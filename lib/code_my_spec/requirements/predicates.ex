defmodule CodeMySpec.Requirements.Predicates do
  @moduledoc """
  Requirement checks as query fragments.

  `RequirementCalculator` interprets `check_type` + `config` in Elixir against
  preloaded lists. The pair is already a predicate name plus its arguments, so
  it can emit a query instead, and "which requirements are satisfied" becomes a
  handful of queries over the node table rather than a pass over every node.

  ## Not for speed — that premise was wrong

  This module was written to kill "4.4 seconds of `Enum` on a 3200-component
  project, against 34ms of preload". Once `RequirementGraph` was instrumented,
  the split came back the other way round on an 880-component project:

      1358 nodes, 26212 edges; nodes 69ms, edges 2500ms

  Node computation — everything here — is under 3% of the time. Edge
  computation is 97% of it, and 26,212 edges against 1,358 nodes is where that
  goes. The original figure almost certainly measured the whole graph and
  attributed it to the part being optimized.

  So converting the remaining check types buys ~69ms and leaves 2.5 seconds
  untouched. What these are still good for is the thing the interpreter cannot
  do at all: answer a question about the *set* — count, filter, or ask which
  requirements a file bears on — without computing every node first. That is
  `Projection.for_file/2`'s job and the reason the graph became rows.

  Anyone reaching for these to make the graph faster should go and look at
  `compute_edges/3` instead.

  ## Composed against `requirements`, not against a graph

  Every function here narrows a query whose node binding is named `:node`, so
  they compose:

      Node
      |> from(as: :node)
      |> Predicates.satisfied(:file_exists, %{role: :spec})

  That is what makes this different from the interpreter it replaces. The
  interpreter answers one node at a time and cannot be asked a question about
  the set; a query can be counted, joined, or restricted to a component without
  computing anything else.

  ## Agreement is the contract

  These must answer exactly what `RequirementCalculator` answers, or the graph
  means one thing to a reader and another to the stop hook. The tests assert
  agreement per component rather than asserting either answer alone, which is
  the same property the delegate batching is held to.

  ## `file_valid` was a decision, until it wasn't

  This module was written expecting to have to choose. `has_valid_role?/2`
  reports the validity of the *first* file of a role, and the table said 880
  components had more than one `implementation` file and 302 more than one
  `spec` — so any-valid, all-valid and first-found would have disagreed, and
  which one to encode looked like a question about what `spec_valid` means.

  It was not. Those duplicates were one row per working copy: `Preloader.load/1`
  loaded every checkout's files, so five harnesses meant five rows per path.
  Scoped to one, no component on this project has two files of a role — checked
  across every harness — and the three semantics collapse into the same query.

  Worth keeping because the shape recurs: a decision that dissolves once the
  data is read correctly is a bug wearing a decision's clothes.
  """

  import Ecto.Query

  alias CodeMySpec.Deploys.Deploy
  alias CodeMySpec.Files.File
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Components.Component
  alias CodeMySpec.Stories.Story

  @doc """
  Narrow `query` to the nodes a check is satisfied for.

  ## `:file_exists`

  The entity has at least one file of `config.role`. Existence only — an invalid
  file still exists, and conflating the two would make `spec_file` and
  `spec_valid` the same requirement.

  ## `:file_valid`

  The entity has a file of `config.role` marked `valid: true`.
  `has_valid_role?/2` distinguishes three unsatisfied cases — no file, an invalid
  one, one not yet validated — for the reason it gives the agent. As a predicate
  they are the same answer.

  Both handle component-owned and story-owned nodes, because a node's owner is
  whichever of `component_id`/`story_id` is set and the file table records the
  same pair. A project-scoped node has neither and matches no file, which is
  correct — no file check is project-scoped.

  ## `:path_exists`

  Project-scoped, where the two above are entity-scoped: these correlate on
  `project_id`. Six definitions use it and all six name a `.code_my_spec/` path
  — a technical strategy, a QA plan, a journey.

  Two config shapes, matching the interpreter: an exact `path`, or a
  `path_prefix` satisfied by any file beneath it. A definition carrying neither
  is satisfied by nothing rather than by everything — the interpreter reports it
  unsatisfied with a reason, and a predicate that matched instead would turn a
  malformed definition into a requirement that is permanently done.

  ## `:field_present` and `:field_true`

  Both read a field on the owning **story**, because both definitions that use
  them are story-scoped: `component_linked` on `component_id`, and
  `bdd_specs_passing` on `specs_ready`. They correlate through `story_id` rather
  than dispatching on the owner, so a component- or project-owned node matches
  no story and reads unsatisfied.

  That is a real limit, and it is deliberate in this direction: `field(s, ^field)`
  needs the field to exist on the schema it is applied to, and `specs_ready` is
  not on components. Supporting all three owners would mean a subquery per
  schema, each valid only for fields that schema has.

  Under-satisfying is the safe failure — work done twice, and obvious. The
  reverse would report a requirement done that nobody did. A test asserts the
  registry still has no non-story field check, so adding one fails there rather
  than silently reading false forever.

  ## `harness_id`

  Every clause scopes its file subquery to one working copy, or blends them all
  when given `nil` — the same asymmetry `Preloader.load/1` applies, strict for
  the agent path and loose for the UI. Passing `nil` from an agent's scope is
  how a file another checkout wrote becomes this one's evidence.
  """
  @spec satisfied(
          Ecto.Query.t(),
          :file_exists
          | :file_valid
          | :path_exists
          | :component_exists
          | :field_present
          | :field_true
          | :deployed
          | :all_deployed,
          map(),
          Ecto.UUID.t() | nil
        ) :: Ecto.Query.t()
  def satisfied(query, check, config, harness_id \\ nil)

  def satisfied(query, :file_exists, %{role: role}, harness_id) do
    where(
      query,
      [node: n],
      exists(
        from(f in File,
          where:
            (f.component_id == parent_as(:node).component_id and not is_nil(f.component_id)) or
              (f.story_id == parent_as(:node).story_id and not is_nil(f.story_id)),
          where: f.role == ^role,
          where: ^harness_filter(harness_id),
          select: 1
        )
      )
    )
  end

  # Deterministic, which it would not have been a commit ago. `has_valid_role?/2`
  # takes the *first* file of a role via `Enum.find/2`, and until
  # `Preloader.load/1` was scoped to a harness it saw one row per checkout — so
  # which file answered depended on row order. With one working copy's files
  # there is exactly one file per `(component, role)`, verified across every
  # harness on this project, and first-found and any-valid are the same question.
  def satisfied(query, :file_valid, %{role: role}, harness_id) do
    where(
      query,
      [node: n],
      exists(
        from(f in File,
          where:
            (f.component_id == parent_as(:node).component_id and not is_nil(f.component_id)) or
              (f.story_id == parent_as(:node).story_id and not is_nil(f.story_id)),
          where: f.role == ^role and f.valid == true,
          where: ^harness_filter(harness_id),
          select: 1
        )
      )
    )
  end

  def satisfied(query, :path_exists, config, harness_id) do
    case {config_value(config, :path), config_value(config, :path_prefix)} do
      {path, _} when is_binary(path) ->
        where(
          query,
          [node: n],
          exists(
            from(f in File,
              where: f.project_id == parent_as(:node).project_id,
              where: f.path == ^path,
              where: ^harness_filter(harness_id),
              select: 1
            )
          )
        )

      {_, prefix} when is_binary(prefix) ->
        pattern = like_prefix(prefix)

        where(
          query,
          [node: n],
          exists(
            from(f in File,
              where: f.project_id == parent_as(:node).project_id,
              where: fragment("? LIKE ? ESCAPE '\\'", f.path, ^pattern),
              where: ^harness_filter(harness_id),
              select: 1
            )
          )
        )

      _ ->
        where(query, [node: _n], fragment("FALSE"))
    end
  end

  # A story is linked when the component it points at exists, not merely when the
  # field is set.
  #
  # `:field_present` could not tell those apart, and the difference became load
  # bearing once the migration started computing component ids rather than
  # looking them up. A component's id is a pure function of its project and
  # module name, so the import can name the component a story belongs to before
  # the working copy has synced it — which is the whole point, since components
  # are rebuilt at the destination and arrive after the import. The id is right;
  # the row is not there yet.
  #
  # Under `:field_present` that reads satisfied: the requirement reports a story
  # linked to a component nobody can open. This module's own rule is the other
  # way round — "under-satisfying is the safe failure … the reverse would report
  # a requirement done that nobody did" — so it asks whether the component is
  # there, and flips to satisfied on its own when the sync creates it.
  #
  # It also retires a real defect rather than only guarding a new path.
  # `stories.component_id` has no foreign key to `components`, so a deleted
  # component leaves its stories pointing at nothing; `Migration`'s own comment
  # records "nine stories came to point at components that no longer existed",
  # and every one of them read as linked. Measured before this landed: 117
  # linked stories, 0 dangling — so nothing in the field changes today.
  def satisfied(query, :component_exists, _config, _harness_id) do
    where(
      query,
      [node: n],
      exists(
        from(s in Story,
          join: c in Component,
          on: c.id == s.component_id,
          where: s.id == parent_as(:node).story_id,
          select: 1
        )
      )
    )
  end

  def satisfied(query, :field_present, config, _harness_id) do
    field = field_name(config)

    where(
      query,
      [node: n],
      exists(
        from(s in Story,
          where: s.id == parent_as(:node).story_id,
          where: not is_nil(field(s, ^field)),
          select: 1
        )
      )
    )
  end

  # Distinct from `:field_present` because `false` is a legitimate value that has
  # to read as unsatisfied. `specs_ready` defaults to `false`, so presence would
  # report every story's specs green the moment the row exists.
  def satisfied(query, :field_true, config, _harness_id) do
    field = field_name(config)

    where(
      query,
      [node: n],
      exists(
        from(s in Story,
          where: s.id == parent_as(:node).story_id,
          where: field(s, ^field) == true,
          select: 1
        )
      )
    )
  end

  # Satisfied when this story is live on `environment` and answered there.
  #
  # Read from `deploys` rather than a flag on the story, so there is nothing to
  # keep in step and nothing to drift. `health_verified_at` is the whole point:
  # the deploy step writes a row only on its success branch, after its own
  # probe passed, so a deploy that shipped and never answered does not satisfy
  # anything (criterion 1964).
  def satisfied(query, :deployed, config, _harness_id) do
    environment = environment_name(config)

    where(
      query,
      [node: n],
      exists(
        from(d in Deploy,
          where: d.story_id == parent_as(:node).story_id,
          where: d.environment == ^environment,
          where: not is_nil(d.health_verified_at),
          select: 1
        )
      )
    )
  end

  # Satisfied when *every* story on the project is live on `environment`.
  #
  # Project-scoped, because "the whole graph is out" is a claim about the
  # project rather than about any one story. Written as "no story is missing a
  # verified deploy" so a story added later un-satisfies it again, which is the
  # behaviour you want from a release gate.
  #
  # A project with no stories reads unsatisfied rather than vacuously true —
  # `exists` on the inner query means there has to be at least one story that
  # *is* deployed. Releasing nothing is not a release.
  def satisfied(query, :all_deployed, config, _harness_id) do
    environment = environment_name(config)

    where(
      query,
      [node: n],
      exists(
        from(s in Story,
          as: :story,
          where: s.project_id == parent_as(:node).project_id,
          where: ^deployed_story(environment),
          select: 1
        )
      ) and
        not exists(
          from(s in Story,
            as: :story,
            where: s.project_id == parent_as(:node).project_id,
            where: ^undeployed_story(environment),
            select: 1
          )
        )
    )
  end

  # Correlated on `parent_as(:story)`, not on the node: inside these the parent
  # is the story being tested, and reading the node's id here would ask whether
  # a *requirement* had been deployed.
  defp deployed_story(environment) do
    dynamic(
      [story: s],
      exists(
        from(d in Deploy,
          where: d.story_id == parent_as(:story).id,
          where: d.environment == ^environment,
          where: not is_nil(d.health_verified_at),
          select: 1
        )
      )
    )
  end

  defp undeployed_story(environment) do
    dynamic([story: s], not (^deployed_story(environment)))
  end

  defp environment_name(config) do
    case config_value(config, :environment) do
      name when is_binary(name) -> name
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
    end
  end

  defp field_name(config) do
    case config_value(config, :field) do
      field when is_atom(field) -> field
      field when is_binary(field) -> String.to_existing_atom(field)
    end
  end

  defp config_value(config, key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  # `_` is a single-character wildcard and `%` matches anything, so a prefix
  # containing either would over-match — and these prefixes are config values
  # holding paths, where `_` is ordinary.
  #
  # `RequirementCalculator` sidesteps this by reading every path for the project
  # and matching in Elixir, which it can afford one project at a time. A query
  # over the whole node table cannot, so the wildcards are escaped instead and
  # the escape character is named explicitly rather than left to the backend's
  # default.
  defp like_prefix(prefix) do
    escaped =
      prefix
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    escaped <> "%"
  end

  # The scoping the moduledoc's argument depends on, which the query did not
  # apply.
  #
  # "Scoped to one, no component has two files of a role, so first-found and
  # any-valid are the same question" — true of the preloader after it was fixed,
  # and not true of this query, which read every checkout's files. The premise
  # was written down and the code did the other thing.
  #
  # Nothing caught it because the agreement test builds one harness, so both
  # sides saw identical rows. A test that asserts two implementations agree
  # proves nothing about the input that makes them differ.
  defp harness_filter(nil), do: dynamic(true)
  defp harness_filter(harness_id), do: dynamic([f], f.harness_id == ^harness_id)

  @doc """
  The base query these compose against, with the node binding named.

  `:node` because every fragment here correlates through `parent_as(:node)`. A
  caller that binds it differently gets a compile error rather than a query that
  silently correlates against the wrong table.

  Deliberately unscoped. Which nodes belong to a project is the caller's
  question — `Projection.project_rows/2` already answers it, and duplicating
  that here would be a second definition of "this project's nodes" to keep in
  step with the first.
  """
  @spec nodes() :: Ecto.Query.t()
  def nodes, do: from(n in Node, as: :node)
end
