defmodule CodeMySpec.Requirements.PredicatesTest do
  @moduledoc """
  Whether a check asked as a query answers what the interpreter answers.

  `RequirementCalculator` walks preloaded lists in Elixir; these emit SQL. They
  have to agree exactly, because the graph means one thing to a reader and
  another to the stop hook otherwise — and the disagreement would be silent, a
  requirement simply reported satisfied by one path and not the other.

  So these compare the two directly per component rather than asserting either
  answer alone, the same property the delegate batching is held to.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures

  import Ecto.Query

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord

  alias CodeMySpec.Requirements.{
    Node,
    Predicates,
    Registry,
    RequirementCalculator,
    RequirementDefinitionData,
    RequirementGraph
  }

  setup do
    %{scope: full_scope_fixture()}
  end

  defp file!(scope, component, role, valid) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      component_id: component.id,
      path: "lib/demo/#{role}_#{System.unique_integer([:positive])}.ex",
      role: role,
      valid: valid
    })
  end

  defp bdd_file!(scope, story, path) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      story_id: story.id,
      path: path,
      role: :bdd_spec,
      valid: true
    })
  end

  defp claim!(criterion, path) do
    criterion |> Ecto.Changeset.change(spec_path: path) |> Repo.update!()
  end

  # What the query says, as a set of story ids.
  defp by_query_story(scope, check, config) do
    Predicates.nodes()
    |> where([node: n], not is_nil(n.story_id))
    |> Predicates.satisfied(check, config, scope.active_working_copy_id)
    |> select([node: n], n.story_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp bdd_specs_exist_definition do
    Enum.find(RequirementDefinitionData.story_graph(), &(&1.name == "bdd_specs_exist"))
  end

  # A real second working copy of the same project. `working_copy_id` is a foreign
  # key, so a generated UUID is not a second checkout — it is a constraint
  # error, and the difference matters because the thing under test is what
  # happens when two checkouts both file rows.
  defp second_harness(scope) do
    {:ok, harness} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "the other checkout",
        device: device_fixture(scope)
      )

    harness.id
  end

  # What the query says, as a set of component ids.
  defp by_query(scope, check, config) do
    Predicates.nodes()
    |> where([node: n], not is_nil(n.component_id))
    |> Predicates.satisfied(check, config)
    |> select([node: n], n.component_id)
    |> Repo.all()
    |> MapSet.new()
    |> then(&{scope, &1})
    |> elem(1)
  end

  # What the interpreter says, from the same rows the graph would load.
  defp by_interpreter(scope, role, check) do
    FileRecord
    |> where([f], f.working_copy_id == ^scope.active_working_copy_id and f.role == ^role)
    |> where([f], not is_nil(f.component_id))
    |> Repo.all()
    |> Enum.filter(fn f -> check == :file_exists or f.valid == true end)
    |> Enum.map(& &1.component_id)
    |> MapSet.new()
  end

  describe "file_exists agrees with the interpreter" do
    test "a component with a spec is in both, one without is in neither", %{scope: scope} do
      with_spec = component_fixture(scope, %{type: "context"})
      _without = component_fixture(scope, %{type: "context"})
      file!(scope, with_spec, :spec, true)

      RequirementGraph.compute_graph(scope)

      assert by_query(scope, :file_exists, %{role: :spec}) ==
               by_interpreter(scope, :spec, :file_exists)
    end

    # Existence does not care about validity, and conflating them would make
    # `spec_file` and `spec_valid` the same requirement.
    test "an invalid file still exists", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      file!(scope, component, :spec, false)

      RequirementGraph.compute_graph(scope)

      assert MapSet.member?(by_query(scope, :file_exists, %{role: :spec}), component.id)
    end
  end

  describe "file_valid agrees with the interpreter" do
    test "only the valid one is satisfied", %{scope: scope} do
      good = component_fixture(scope, %{type: "context"})
      bad = component_fixture(scope, %{type: "context"})
      file!(scope, good, :spec, true)
      file!(scope, bad, :spec, false)

      RequirementGraph.compute_graph(scope)

      satisfied = by_query(scope, :file_valid, %{role: :spec})

      assert satisfied == by_interpreter(scope, :spec, :file_valid)
      assert MapSet.member?(satisfied, good.id)
      refute MapSet.member?(satisfied, bad.id)
    end

    # `valid: nil` is "synced but not yet validated", which `has_valid_role?/2`
    # reports as unsatisfied with its own reason. A predicate has to agree with
    # the verdict even though it cannot carry the reason.
    test "a file not yet validated is not valid", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      file!(scope, component, :spec, nil)

      RequirementGraph.compute_graph(scope)

      refute MapSet.member?(by_query(scope, :file_valid, %{role: :spec}), component.id)
    end
  end

  describe "bdd_specs_covered agrees with the interpreter, per criterion" do
    # Issue 644279a9: a story with one spex file used to read satisfied no
    # matter how many criteria it had. Here one story has every criterion
    # claimed and filed, the other has one of two — the case that used to be
    # indistinguishable from fully covered.
    test "a story with every criterion covered is satisfied; a partly covered one is not",
         %{scope: scope} do
      covered = story_fixture(scope, %{criteria: []})
      c1 = criterion_fixture(scope, covered)
      c2 = criterion_fixture(scope, covered)
      claim!(c1, "test/spex/covered/one_test.exs")
      claim!(c2, "test/spex/covered/two_test.exs")
      bdd_file!(scope, covered, "test/spex/covered/one_test.exs")
      bdd_file!(scope, covered, "test/spex/covered/two_test.exs")

      partial = story_fixture(scope, %{criteria: []})
      p1 = criterion_fixture(scope, partial)
      _p2 = criterion_fixture(scope, partial)
      claim!(p1, "test/spex/partial/one_test.exs")
      bdd_file!(scope, partial, "test/spex/partial/one_test.exs")

      RequirementGraph.compute_graph(scope)

      satisfied = by_query_story(scope, :bdd_specs_covered, %{role: :bdd_spec})

      assert MapSet.member?(satisfied, covered.id)
      refute MapSet.member?(satisfied, partial.id)

      definition = bdd_specs_exist_definition()

      assert %{satisfied: true} =
               RequirementCalculator.compute_one(
                 scope,
                 covered,
                 definition,
                 Files.list_story_files(scope, covered.id)
               )

      assert %{satisfied: false} =
               RequirementCalculator.compute_one(
                 scope,
                 partial,
                 definition,
                 Files.list_story_files(scope, partial.id)
               )
    end

    test "a criterion's file existing is not enough without being claimed", %{scope: scope} do
      story = story_fixture(scope, %{criteria: []})
      criterion_fixture(scope, story)
      bdd_file!(scope, story, "test/spex/unclaimed/one_test.exs")

      RequirementGraph.compute_graph(scope)

      refute MapSet.member?(
               by_query_story(scope, :bdd_specs_covered, %{role: :bdd_spec}),
               story.id
             )

      assert %{satisfied: false} =
               RequirementCalculator.compute_one(
                 scope,
                 story,
                 bdd_specs_exist_definition(),
                 Files.list_story_files(scope, story.id)
               )
    end

    # Nothing to cover is not coverage — same reasoning `:all_deployed` uses for
    # a project with no stories.
    test "a story with no criteria is unsatisfied, not vacuously true", %{scope: scope} do
      story = story_fixture(scope, %{criteria: []})

      RequirementGraph.compute_graph(scope)

      refute MapSet.member?(
               by_query_story(scope, :bdd_specs_covered, %{role: :bdd_spec}),
               story.id
             )

      assert %{satisfied: false} =
               RequirementCalculator.compute_one(
                 scope,
                 story,
                 bdd_specs_exist_definition(),
                 Files.list_story_files(scope, story.id)
               )
    end
  end

  # The input that makes the two implementations differ, which the agreement
  # tests above cannot produce because they build one harness.
  #
  # `by_interpreter/3` filters on `working_copy_id`; the query did not. With a single
  # working copy both read the same rows and agreed perfectly, so the suite
  # asserted equality under exactly the condition where the difference cannot
  # appear. The moduledoc's argument — "scoped to one, first-found and any-valid
  # are the same question" — was written about a scoping the code never applied.
  describe "another checkout's files are not this one's evidence" do
    test "a spec written in a second harness does not satisfy the first", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})
      other_harness = second_harness(scope)

      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: other_harness,
        component_id: component.id,
        path: "lib/demo/written_elsewhere.ex",
        role: :spec,
        valid: true
      })

      RequirementGraph.compute_graph(scope)

      satisfied =
        Predicates.nodes()
        |> where([node: n], not is_nil(n.component_id))
        |> Predicates.satisfied(:file_exists, %{role: :spec}, scope.active_working_copy_id)
        |> select([node: n], n.component_id)
        |> Repo.all()
        |> MapSet.new()

      refute MapSet.member?(satisfied, component.id),
             "a file that exists only in another working copy is work this checkout " <>
               "still has to do — reporting it done is work skipped and never noticed"
    end

    test "a nil harness blends every checkout, as the preloader does", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"})

      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: second_harness(scope),
        component_id: component.id,
        path: "lib/demo/written_elsewhere.ex",
        role: :spec,
        valid: true
      })

      RequirementGraph.compute_graph(scope)

      satisfied =
        Predicates.nodes()
        |> where([node: n], not is_nil(n.component_id))
        |> Predicates.satisfied(:file_exists, %{role: :spec}, nil)
        |> select([node: n], n.component_id)
        |> Repo.all()
        |> MapSet.new()

      assert MapSet.member?(satisfied, component.id),
             "the loose default is the UI's read — one rule with the preloader, not " <>
               "a second one invented here"
    end
  end

  describe "path_exists" do
    defp project_file!(scope, path, working_copy_id \\ nil) do
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: working_copy_id || scope.active_working_copy_id,
        path: path,
        role: :architecture,
        valid: true
      })
    end

    defp path_satisfied?(scope, config) do
      Predicates.nodes()
      |> where([node: n], n.name == "technical_strategy")
      |> Predicates.satisfied(:path_exists, config, scope.active_working_copy_id)
      |> Repo.exists?()
    end

    test "an exact path that is tracked satisfies it", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      refute path_satisfied?(scope, %{path: ".code_my_spec/architecture/decisions.md"})

      project_file!(scope, ".code_my_spec/architecture/decisions.md")

      assert path_satisfied?(scope, %{path: ".code_my_spec/architecture/decisions.md"})
    end

    test "string keys work, because definitions carry both", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      project_file!(scope, ".code_my_spec/architecture/decisions.md")

      assert path_satisfied?(scope, %{"path" => ".code_my_spec/architecture/decisions.md"})
    end

    test "a prefix is satisfied by any file beneath it", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      refute path_satisfied?(scope, %{path_prefix: ".code_my_spec/qa/"})

      project_file!(scope, ".code_my_spec/qa/journey.md")

      assert path_satisfied?(scope, %{path_prefix: ".code_my_spec/qa/"})
    end

    # The trap `RequirementCalculator` avoids by matching in Elixir. `_` is a
    # single-character wildcard in LIKE, so an unescaped prefix would match a
    # directory that merely resembles it — and these prefixes are paths, where
    # `_` is an ordinary character.
    test "an underscore in the prefix is a literal, not a wildcard", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      project_file!(scope, ".code_my_spec/qaXjourney/plan.md")

      refute path_satisfied?(scope, %{path_prefix: ".code_my_spec/qa_journey/"}),
             "`qa_journey` must not match `qaXjourney` — an over-matching prefix " <>
               "reports a requirement done because a differently-named directory exists"
    end

    test "a percent in the prefix is a literal too", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      project_file!(scope, ".code_my_spec/anything/at/all.md")

      refute path_satisfied?(scope, %{path_prefix: ".code_my_spec/%/"})
    end

    # A malformed definition must be satisfied by nothing, not by everything.
    test "no path and no prefix matches nothing", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      project_file!(scope, ".code_my_spec/architecture/decisions.md")

      refute path_satisfied?(scope, %{}),
             "matching everything would turn a definition missing its config into a " <>
               "requirement that is permanently done"
    end

    test "another checkout's file does not satisfy it", %{scope: scope} do
      RequirementGraph.compute_graph(scope)
      project_file!(scope, ".code_my_spec/architecture/decisions.md", second_harness(scope))

      refute path_satisfied?(scope, %{path: ".code_my_spec/architecture/decisions.md"})
    end

    # The property this module promises and the one that caught nothing when the
    # harness scoping was missing: the query and the interpreter must return the
    # same verdict, not merely plausible ones.
    #
    # Both directions are asserted from the same rows. All six `path_exists`
    # definitions ship an exact `path`, so `technical_strategy` is a real
    # definition rather than one invented for the test; the prefix cases below
    # exercise config the interpreter supports but no definition uses yet, which
    # is where the two implementations are most free to drift.
    for {label, config, path, expected} <- [
          {"an exact path that is tracked", %{path: ".code_my_spec/architecture/decisions.md"},
           ".code_my_spec/architecture/decisions.md", true},
          {"an exact path that is not", %{path: ".code_my_spec/architecture/decisions.md"},
           ".code_my_spec/architecture/other.md", false},
          {"a prefix with a file beneath it", %{path_prefix: ".code_my_spec/qa/"},
           ".code_my_spec/qa/journey.md", true},
          {"a prefix with nothing beneath it", %{path_prefix: ".code_my_spec/qa/"},
           ".code_my_spec/elsewhere/journey.md", false},
          {"a prefix whose underscore is literal", %{path_prefix: ".code_my_spec/qa_journey/"},
           ".code_my_spec/qaXjourney/plan.md", false}
        ] do
      test "query and interpreter agree on #{label}", %{scope: scope} do
        RequirementGraph.compute_graph(scope)
        project_file!(scope, unquote(path))

        config = unquote(Macro.escape(config))
        definition = %{name: "technical_strategy", check_type: :path_exists, config: config}

        %{satisfied: interpreted} =
          RequirementCalculator.compute_one(scope, scope.active_project, definition, [], nil)

        assert path_satisfied?(scope, config) == interpreted
        assert interpreted == unquote(expected)
      end
    end
  end

  describe "field checks on a story" do
    # `ready_for_dev: true` is not incidental. `Preloader.load/1` gates on it —
    # only stories released for development project into the graph, so a parked
    # story produces no nodes at all and every assertion below would compare two
    # empty sets and pass. That is how these tests first failed: not because the
    # predicate was wrong, but because there was nothing for it to match.
    defp story!(scope, attrs) do
      {:ok, story} =
        CodeMySpec.Stories.create_story(
          scope,
          Map.merge(
            %{
              title: "A story #{System.unique_integer([:positive])}",
              description: "for a field",
              ready_for_dev: true
            },
            attrs
          )
        )

      story
    end

    defp field_satisfied(scope, name, check, config) do
      Predicates.nodes()
      |> where([node: n], n.name == ^name)
      |> Predicates.satisfied(check, config, scope.active_working_copy_id)
      |> select([node: n], n.story_id)
      |> Repo.all()
      |> MapSet.new()
    end

    test "component_linked follows whether the story has one", %{scope: scope} do
      linked = story!(scope, %{component_id: component_fixture(scope, %{type: "context"}).id})
      unlinked = story!(scope, %{})

      RequirementGraph.compute_graph(scope)

      satisfied =
        field_satisfied(scope, "component_linked", :field_present, %{field: :component_id})

      assert MapSet.member?(satisfied, linked.id)
      refute MapSet.member?(satisfied, unlinked.id)
    end

    # The reason `:field_true` exists separately. `specs_ready` defaults to
    # `false`, so a presence check would call every story's specs green the
    # moment the row exists.
    test "specs_ready false is unsatisfied, not merely present", %{scope: scope} do
      story = story!(scope, %{})

      RequirementGraph.compute_graph(scope)

      refute MapSet.member?(
               field_satisfied(scope, "bdd_specs_passing", :field_true, %{field: :specs_ready}),
               story.id
             )

      assert MapSet.member?(
               field_satisfied(scope, "bdd_specs_passing", :field_present, %{
                 field: :specs_ready
               }),
               story.id
             ),
             "present-but-false is exactly the case the two checks disagree on; if " <>
               "they agreed here there would be no reason for both to exist"
    end

    test "a story whose specs are ready satisfies it", %{scope: scope} do
      ready = story!(scope, %{specs_ready: true})
      not_ready = story!(scope, %{})

      RequirementGraph.compute_graph(scope)

      satisfied = field_satisfied(scope, "bdd_specs_passing", :field_true, %{field: :specs_ready})

      assert MapSet.member?(satisfied, ready.id)
      refute MapSet.member?(satisfied, not_ready.id)
    end

    test "query and interpreter agree", %{scope: scope} do
      ready = story!(scope, %{specs_ready: true})
      RequirementGraph.compute_graph(scope)

      definition = %{
        name: "bdd_specs_passing",
        check_type: :field_true,
        config: %{field: :specs_ready}
      }

      %{satisfied: interpreted} =
        RequirementCalculator.compute_one(scope, ready, definition, [], nil)

      by_query =
        MapSet.member?(
          field_satisfied(scope, "bdd_specs_passing", :field_true, %{field: :specs_ready}),
          ready.id
        )

      assert by_query == interpreted
      assert interpreted
    end

    # The guard for the limit documented on `satisfied/4`: these checks all
    # correlate through `story_id`, so one on a component or project would read
    # unsatisfied forever. Under-satisfying is the safe direction, but silently
    # is not — this fails when someone adds one, which is the moment to decide
    # whether to grow the predicate or leave that definition interpreted.
    #
    # `:component_exists` is in the list for the same reason the other two are:
    # it joins `parent_as(:node).story_id`. It is not a field check, but the
    # limit it shares is what this guards.
    test "no story-correlated check has escaped the story graph" do
      field_checks = fn defs ->
        for d <- defs,
            d.check_type in [:field_present, :field_true, :component_exists],
            do: d.name
      end

      # Guard against the assertion below passing on empty lists: if these
      # lookups returned nothing, "no offenders" would be true and mean nothing.
      #
      # `bdd_specs_passing` was here and is now a `:delegate`. It read
      # `specs_ready` as a bare field, and a bare field read cannot tell a latch
      # that was earned from one set by a gate that could not find the story's
      # specs and mistook that for their passing — which is what happened, on 47
      # of 61 stories in one project. `SpecsPassingChecker` keeps the field as
      # the latch and adds the contradiction test, and that needs the database
      # twice, so it cannot be a query clause here.
      #
      # Nothing regressed by leaving: `Predicates.satisfied/4` has no production
      # callers yet — `RequirementCalculator` interprets — so this is a query
      # form waiting to be wired up, not a fast path that lost a member.
      assert field_checks.(RequirementDefinitionData.story_graph()) |> Enum.sort() ==
               ["component_linked"],
             "the story graph is where field checks live; if this moved, the search " <>
               "below is looking in the wrong places"

      offenders =
        for {type, defs} <- [
              {"component", Registry.get_requirements_for_type("context")},
              {"project", Registry.get_project_requirements()}
            ],
            name <- field_checks.(defs),
            do: {type, name}

      assert offenders == [],
             "these correlate through story_id and would read unsatisfied forever: " <>
               inspect(offenders)
    end
  end

  # The point of a query over an interpreter: it can be asked about the set.
  # `RequirementCalculator` answers one node at a time and cannot be.
  test "the predicate counts without computing a graph", %{scope: scope} do
    a = component_fixture(scope, %{type: "context"})
    b = component_fixture(scope, %{type: "context"})
    file!(scope, a, :implementation, true)
    file!(scope, b, :implementation, true)

    RequirementGraph.compute_graph(scope)

    # `implementation_file`, not `spec_file`: this project's configuration
    # strips the spec requirements, so no `spec_file` node exists to count and
    # the assertion below would have passed on 0 == 0.
    assert Repo.aggregate(from(n in Node, where: n.name == "implementation_file"), :count) == 2

    count =
      Predicates.nodes()
      |> where([node: n], n.name == "implementation_file")
      |> Predicates.satisfied(:file_exists, %{role: :implementation})
      |> Repo.aggregate(:count)

    assert count == 2
  end

  test "nodes/0 names its binding so fragments can correlate", %{scope: scope} do
    component_fixture(scope, %{type: "context"})
    RequirementGraph.compute_graph(scope)

    assert Repo.aggregate(Predicates.nodes(), :count) == Repo.aggregate(Node, :count)
  end
end
