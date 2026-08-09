defmodule CodeMySpec.AgentTasks.WriteBddSpecsPromptTest do
  @moduledoc """
  What the BDD spec prompt says when the server holds no working copy.

  Under a light harness that is every prompt, and two of its statements were
  confidently wrong. It called a 200-line implemented module a stub and told the
  agent to invent the public API — which produces spex written against an
  interface that does not exist, failing in ways that look like implementation
  gaps. And it named `MyAppSpex.Case` and `test/support/my_app_spex_case.ex`,
  which exist in no project, surrounded by prose naming real criteria and real
  paths so the placeholders read as deliberate.

  Both came from the same place: a file read that cannot succeed, and a
  catch-all that turned "could not look" into a definite claim.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Stories

  setup do
    # Deliberately not the fixture default, which is `MyApp` — the exact string
    # the placeholder produces. With that name a correct implementation and a
    # hardcoded `MyAppSpex` are indistinguishable, and the test proves nothing.
    scope = full_scope_fixture(%{module_name: "Acme"})

    component =
      component_fixture(scope, %{
        name: "ContentPublishing",
        module_name: "CodeMySpec.Provisioning.ContentPublishing",
        type: "context"
      })

    story = story_fixture(scope, %{title: "My blog publishes from my repo to my own bucket"})
    {:ok, story} = Stories.set_story_component(scope, story, component.id)

    # No environment: the light-harness scope. This is the case under test.
    %{scope: %{scope | environment: nil, cwd: nil}, story: story, component: component}
  end

  defp prompt(scope, story) do
    {:ok, text} = WriteBddSpecs.command(scope, %{story_id: story.id})
    text
  end

  describe "the case module" do
    test "is the project's, not a MyApp placeholder", %{scope: scope, story: story} do
      text = prompt(scope, story)

      refute text =~ "MyAppSpex",
             "the placeholder reached agents as an instruction — no project has it"

      refute text =~ "my_app_spex_case.ex"

      assert text =~ "AcmeSpex",
             "with no mix.exs to read, the project's own module name is the honest answer"

      assert text =~ "acme_spex_case.ex"
    end
  end

  describe "the component under test" do
    # The damaging claim. An implemented module described as empty, with an
    # explicit instruction to invent the interface.
    test "an implemented file is not called a stub", %{
      scope: scope,
      story: story,
      component: component
    } do
      {1, _} =
        Files.upsert_files(scope, [
          %{
            path: "lib/code_my_spec/provisioning/content_publishing.ex",
            role: :implementation,
            component_id: component.id,
            fingerprint: "abc",
            mtime: DateTime.utc_now(),
            size: 200
          }
        ])

      text = prompt(scope, story)

      refute text =~ "this component is a stub",
             "it is 200 lines and implemented; told otherwise, an agent writes spex " <>
               "against an interface it made up"

      refute text =~ "Do not infer an interface from the empty module"
      assert text =~ "Do not treat this as a stub"
      assert text =~ "content_publishing.ex"
    end

    # The other half: a component with nothing on disk really is a stub, and the
    # original framing is right for it. Losing that would be the opposite error.
    test "a component with no file is still framed as a stub", %{scope: scope, story: story} do
      text = prompt(scope, story)

      assert text =~ "this component is a stub",
             "with no file reported anywhere, there is genuinely nothing to read"
    end
  end
end
