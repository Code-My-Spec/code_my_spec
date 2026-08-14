defmodule CodeMySpec.TaskHelpTest do
  # async: false — these tests set the global :task_help_dir app env.
  use ExUnit.Case, async: false

  import CodeMySpec.EnvironmentFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.TaskHelp
  alias CodeMySpec.TaskHelp.Help
  alias CodeMySpec.Users.Scope

  @arch CodeMySpec.AgentTasks.ArchitectureDesign

  setup do
    env = memory_environment_fixture()
    dir = CodeMySpec.TempFile.dir("task_help")
    File.mkdir_p!(dir)
    Application.put_env(:code_my_spec, :task_help_dir, dir)

    on_exit(fn ->
      Application.delete_env(:code_my_spec, :task_help_dir)
      File.rm_rf(dir)
    end)

    %{scope: %Scope{environment: env}, env: env, dir: dir}
  end

  describe "fetch/2 — framework default (priv)" do
    test "returns the shipped explainer + sidecar video", %{scope: scope, dir: dir} do
      File.write!(Path.join(dir, "architecture_design.md"), "# Architecture\n\nMapping stories to modules.")

      File.write!(
        Path.join(dir, "architecture_design.yaml"),
        ~s(video_url: "https://videos.example.com/arch.mp4"\n)
      )

      assert {:ok, %Help{task_type: @arch, body: body, video_url: url}} =
               TaskHelp.fetch(scope, @arch)

      assert body =~ "Mapping stories to modules"
      assert url == "https://videos.example.com/arch.mp4"
    end

    test "video_url is nil when the default has no sidecar", %{scope: scope, dir: dir} do
      File.write!(Path.join(dir, "architecture_design.md"), "# Architecture\n")
      assert {:ok, %Help{video_url: nil}} = TaskHelp.fetch(scope, @arch)
    end
  end

  describe "fetch/2 — project override" do
    test "a project override wins over the framework default", %{scope: scope, env: env, dir: dir} do
      File.write!(Path.join(dir, "architecture_design.md"), "FRAMEWORK DEFAULT")

      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/help/architecture_design.md",
          "PROJECT OVERRIDE"
        )

      :ok =
        Environments.write_file(
          env,
          ".code_my_spec/content/help/architecture_design.yaml",
          ~s(video_url: "https://videos.example.com/override.mp4"\n)
        )

      assert {:ok, %Help{body: "PROJECT OVERRIDE", video_url: "https://videos.example.com/override.mp4"}} =
               TaskHelp.fetch(scope, @arch)
    end
  end

  describe "fetch/2 — generic fallback" do
    test "returns :generic when neither override nor default exists", %{scope: scope} do
      assert :generic = TaskHelp.fetch(scope, CodeMySpec.AgentTasks.ContextSpec)
    end
  end
end
