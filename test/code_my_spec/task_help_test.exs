defmodule CodeMySpec.TaskHelpTest do
  use ExUnit.Case, async: true

  import CodeMySpec.EnvironmentFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.TaskHelp
  alias CodeMySpec.TaskHelp.Help
  alias CodeMySpec.Users.Scope

  @video_url "https://videos.example.com/architecture-design.mp4"

  setup do
    env = memory_environment_fixture()
    %{scope: %Scope{environment: env}, env: env}
  end

  describe "fetch/2" do
    test "returns curated help with the sidecar video for a task type with content",
         %{scope: scope, env: env} do
      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/architecture_design.md",
          "# Designing your architecture\n\nMaps stories to modules.\n"
        )

      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/architecture_design.yaml",
          """
          title: "Designing your architecture"
          slug: "architecture-design"
          type: "documentation"
          video_url: "#{@video_url}"
          """
        )

      assert {:ok, %Help{task_type: CodeMySpec.AgentTasks.ArchitectureDesign} = help} =
               TaskHelp.fetch(scope, CodeMySpec.AgentTasks.ArchitectureDesign)

      assert help.body =~ "Designing your architecture"
      assert help.video_url == @video_url
    end

    test "returns curated help with nil video when the sidecar has no video_url",
         %{scope: scope, env: env} do
      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/architecture_design.md",
          "# Designing your architecture\n"
        )

      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/architecture_design.yaml",
          """
          title: "Designing your architecture"
          slug: "architecture-design"
          type: "documentation"
          """
        )

      assert {:ok, %Help{video_url: nil}} =
               TaskHelp.fetch(scope, CodeMySpec.AgentTasks.ArchitectureDesign)
    end

    test "returns curated help with nil video when the sidecar is missing entirely",
         %{scope: scope, env: env} do
      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/architecture_design.md",
          "# Designing your architecture\n"
        )

      assert {:ok, %Help{video_url: nil}} =
               TaskHelp.fetch(scope, CodeMySpec.AgentTasks.ArchitectureDesign)
    end

    test "falls back to :generic when no content document exists for the task type",
         %{scope: scope} do
      assert :generic = TaskHelp.fetch(scope, CodeMySpec.AgentTasks.ContextSpec)
    end
  end
end
