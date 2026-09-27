defmodule CodeMySpec.AgentTasks.WriteBddSpecsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures

  @moduletag :tmp_dir

  # ============================================================================
  # Helpers
  # ============================================================================

  defp scope_with_cwd(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp create_story_with_component(scope, opts \\ %{}) do
    component =
      component_fixture(
        scope,
        Map.merge(
          %{type: "liveview", module_name: "MyAppWeb.UserLoginLive"},
          opts[:component] || %{}
        )
      )

    story =
      story_fixture(
        scope,
        Map.merge(
          %{
            title: "User Login Feature",
            component_id: component.id,
            criteria: []
          },
          opts[:story] || %{}
        )
      )

    c1 = criterion_fixture(scope, story, %{description: "User can log in with valid credentials"})

    c2 =
      criterion_fixture(scope, story, %{description: "User sees error with invalid credentials"})

    story = %{story | criteria: [c1, c2]}

    {story, component}
  end

  defp task_for_story(story) do
    %{story_id: story.id, component_id: story.component_id, project_id: nil}
  end

  defp write_valid_spec!(tmp_dir, story, criterion) do
    spec_path = BddSpecs.spec_file_path(story, criterion)
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    File.write!(full_path, """
    defmodule MyAppSpex.UserLoginSpex do
      use MyAppSpex.Case

      spex "user login" do
        scenario "valid credentials" do
          given_ "setup", _context do
            {:ok, %{user: "test"}}
          end

          when_ "login", context do
            {:ok, context}
          end

          then_ "success", context do
            assert context.user
            :ok
          end
        end
      end
    end
    """)

    full_path
  end

  # ============================================================================
  # command/2
  # ============================================================================

  describe "command/2" do
    test "returns prompt with story context and criteria", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task)
      assert prompt =~ story.title
      assert prompt =~ "User can log in with valid credentials"
      assert prompt =~ "User sees error with invalid credentials"
    end

    test "includes component module and type", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, component} = create_story_with_component(scope)
      task = task_for_story(story)

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task)
      assert prompt =~ component.module_name
      assert prompt =~ "liveview"
    end

    test "includes expected file paths for each criterion", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task)

      for criterion <- story.criteria do
        spec_path = BddSpecs.spec_file_path(story, criterion)
        assert prompt =~ spec_path
      end
    end

    test "names LiveView as the likely surface for liveview components", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task)
      assert prompt =~ ~r/liveview/i
      assert prompt =~ "bdd/spex/"
    end

    test "names HTTP/controller as the likely surface for controller components", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_cwd(tmp_dir)

      {story, _component} =
        create_story_with_component(scope,
          component: %{type: "controller", module_name: "MyAppWeb.SessionController"}
        )

      task = task_for_story(story)

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task)
      assert prompt =~ ~r/controller|HTTP/i
      assert prompt =~ "bdd/spex/"
    end

    test "points at the spex DSL playbook and names step macros", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task)
      assert prompt =~ "given_"
      assert prompt =~ "when_"
      assert prompt =~ "then_"
      assert prompt =~ "bdd/spex/"
    end

    test "returns error when story not found", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      task = %{story_id: 999_999, component_id: nil, project_id: nil}

      assert {:error, {:story_not_found, message}} = WriteBddSpecs.command(scope, task)
      assert message =~ "999999"
    end

    test "returns error when no story_id", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      task = %{story_id: nil, component_id: nil, project_id: nil}

      assert {:error, {:story_not_specified, message}} = WriteBddSpecs.command(scope, task)
      assert message =~ "story_id"
    end

    test "returns error when story has no component linked", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      story = story_fixture(scope, %{title: "Unlinked", component_id: nil, criteria: []})
      task = %{story_id: story.id, component_id: nil, project_id: nil}

      assert {:error, {:component_not_linked, message}} = WriteBddSpecs.command(scope, task)
      assert message =~ "has no surface component linked"
      assert message =~ "set_story_component"
    end
  end

  # ============================================================================
  # Prompt guidance that used to be generic
  # ============================================================================

  describe "command/2 — a component with no implementation yet" do
    test "frames a stub as the starting point, not as a file to go read", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)

      {story, _component} =
        create_story_with_component(scope,
          component: %{type: "context", module_name: "MyApp.Qa"}
        )

      File.mkdir_p!(Path.join(tmp_dir, "lib/my_app"))
      File.write!(Path.join(tmp_dir, "lib/my_app/qa.ex"), "defmodule MyApp.Qa do\nend\n")

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task_for_story(story))

      assert prompt =~ "this component is a stub",
             """
             Telling an agent to "open the file to see the public API" when the
             file is an empty module sends it to learn nothing, then work out
             on its own that the instruction did not apply.

             #{prompt}
             """

      refute prompt =~ "open the file before writing specs to see the public API"
    end

    test "still surfaces the moduledoc when there is a real implementation", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)

      {story, _component} =
        create_story_with_component(scope,
          component: %{type: "context", module_name: "MyApp.Qa"}
        )

      File.mkdir_p!(Path.join(tmp_dir, "lib/my_app"))

      File.write!(
        Path.join(tmp_dir, "lib/my_app/qa.ex"),
        """
        defmodule MyApp.Qa do
          @moduledoc "Records QA attempts."
          def list_attempts(scope), do: []
        end
        """
      )

      assert {:ok, prompt} = WriteBddSpecs.command(scope, task_for_story(story))

      refute prompt =~ "this component is a stub",
             "a module with functions has an interface worth reading"
    end
  end

  describe "command/2 — per-criterion surface" do
    test "reads the surface off each scenario's When step", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)

      component =
        component_fixture(scope, %{type: "context", module_name: "MyApp.Qa"})

      story = story_fixture(scope, %{component_id: component.id, criteria: []})

      mcp =
        criterion_fixture(scope, story, %{
          description: "attempts are listed",
          body: "Given a story\nWhen the agent calls list_qa_attempts\nThen it sees them"
        })

      live =
        criterion_fixture(scope, story, %{
          description: "attempts show on the page",
          body: "Given a story\nWhen the user navigates to the story page\nThen they see them"
        })

      assert {:ok, prompt} = WriteBddSpecs.command(scope, %{story_id: story.id})

      mcp_block = criterion_block(prompt, mcp.id)
      live_block = criterion_block(prompt, live.id)

      assert mcp_block =~ "MCP tool"

      assert live_block =~ "LiveView",
             """
             One sentence above the list cannot describe a story whose criteria
             span surfaces, and that is the normal case — a tool and the view
             that shows its result. The scenario already said which is which.

             #{prompt}
             """
    end

    test "says nothing when the scenario body names no surface", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      component = component_fixture(scope, %{type: "context", module_name: "MyApp.Qa"})
      story = story_fixture(scope, %{component_id: component.id, criteria: []})

      criterion =
        criterion_fixture(scope, story, %{
          description: "something happens",
          body: "Given a thing\nWhen it changes\nThen it is different"
        })

      assert {:ok, prompt} = WriteBddSpecs.command(scope, %{story_id: story.id})

      refute criterion_block(prompt, criterion.id) =~ "**Surface**",
             "a wrong surface is worse than none — the agent trusts it"
    end
  end

  defp criterion_block(prompt, criterion_id) do
    prompt
    |> String.split(~r/^### Criterion /m)
    |> Enum.find("", &String.starts_with?(&1, "#{criterion_id}:"))
  end

  # ============================================================================
  # evaluate/2
  # ============================================================================

  describe "evaluate/2" do
    test "returns :valid when all specs exist and parse correctly", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      for criterion <- story.criteria do
        write_valid_spec!(tmp_dir, story, criterion)
      end

      assert {:ok, :valid} = WriteBddSpecs.evaluate(scope, task)
    end

    test "returns :invalid when spec file is missing", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      # Write only the first criterion's spec
      write_valid_spec!(tmp_dir, story, hd(story.criteria))

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, task)
      assert feedback =~ "Spec file not found"
    end

    test "returns :invalid when spec has no scenarios", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      {story, _component} = create_story_with_component(scope)
      task = task_for_story(story)

      for criterion <- story.criteria do
        spec_path = BddSpecs.spec_file_path(story, criterion)
        full_path = Path.join(tmp_dir, spec_path)
        full_path |> Path.dirname() |> File.mkdir_p!()

        File.write!(full_path, """
        defmodule MyAppSpex.EmptySpex do
          use MyAppSpex.Case
          spex "empty" do
          end
        end
        """)
      end

      assert {:ok, :invalid, feedback} = WriteBddSpecs.evaluate(scope, task)
      assert feedback =~ "at least one scenario"
    end

    test "returns error when story not found", %{tmp_dir: tmp_dir} do
      scope = scope_with_cwd(tmp_dir)
      task = %{story_id: 999_999, component_id: nil, project_id: nil}

      assert {:error, {:story_not_found, _message}} = WriteBddSpecs.evaluate(scope, task)
    end
  end
end
