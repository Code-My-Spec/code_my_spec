defmodule CmsHarness.SetupTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Setup

  setup do
    CodeMySpecTest.ScriptedGeneratorRunner.script(
      &CmsHarness.Projects.Generator.Runner.Real.cmd/3
    )

    root = Path.join(System.tmp_dir!(), "machine-setup-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    log = Path.join(root, "commands.log")
    File.mkdir_p!(bin)
    File.write!(log, "")
    previous_path = System.get_env("PATH")

    Enum.each(
      [
        {"psql", "psql (PostgreSQL) 16.4\nvector|0.8.0"},
        {"mise", "erlang 27.2\nelixir 1.18.1"},
        {"erl", "27"},
        {"elixir", "Elixir 1.18.1"},
        {"mix", "mix cms.new"},
        {"vibium", "Vibium 1.0.0"},
        {"just", "just 1.40.0"}
      ],
      fn {name, output} ->
        path = Path.join(bin, name)

        File.write!(path, """
        #!/bin/sh
        printf '%s\\n' '#{name}' >> '#{log}'
        printf '%s\\n' '#{output}'
        """)

        File.chmod!(path, 0o700)
      end
    )

    System.put_env("PATH", bin)

    on_exit(fn ->
      restore_path(previous_path)
      File.rm_rf!(root)
    end)

    %{
      root: root,
      bin: bin,
      log: log,
      original_path: previous_path,
      opts: [directory: Path.join(root, "setup")]
    }
  end

  test "reading a fresh machine does not execute or create setup", ctx do
    assert :none = Setup.status(ctx.opts)
    assert File.read!(ctx.log) == ""
    refute File.exists?(ctx.opts[:directory])
  end

  test "records each check once and reopening preserves timestamps and output", ctx do
    assert {:ok, first} = Setup.check_prerequisites(ctx.opts)
    assert Setup.prerequisites_passed?(first)
    assert first["state"] == "done"
    assert length(first["steps"]) == 8
    assert Enum.all?(first["steps"], &is_binary(&1["finished_at"]))
    assert Enum.all?(first["steps"], &(length(&1["commands"]) == 1))
    recorded = File.read!(ctx.log)
    assert length(String.split(recorded, "\n", trim: true)) == 8
    assert {:ok, ^first} = Setup.status(ctx.opts)
    assert {:ok, ^first} = Setup.check_prerequisites(ctx.opts)
    assert File.read!(ctx.log) == recorded
    assert first == first["results_path"] |> File.read!() |> Jason.decode!()
  end

  test "an explicit new run preserves the previous results file", ctx do
    assert {:ok, first} = Setup.check_prerequisites(ctx.opts)
    previous_bytes = File.read!(first["results_path"])
    assert {:ok, next} = Setup.new_run(ctx.opts)
    refute next["run_id"] == first["run_id"]
    assert next["state"] == "not_started"
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    assert Setup.prerequisites_passed?(checked)
    assert length(String.split(File.read!(ctx.log), "\n", trim: true)) == 16
    assert File.read!(first["results_path"]) == previous_bytes
  end

  test "checks the generator without requiring a standalone harness executable", ctx do
    File.write!(Path.join(ctx.bin, "mix"), """
    #!/bin/sh
    case "$*" in
      "help cms.new") printf 'mix cms.new\\n' ;;
      *) printf 'unsupported command\\n' >&2; exit 1 ;;
    esac
    """)

    assert {:ok, result} = Setup.check_prerequisites(ctx.opts)
    assert Setup.prerequisites_passed?(result)
    cms = Enum.find(result["steps"], &(&1["key"] == "cms"))
    assert cms["state"] == "done"
    assert [%{"exit_status" => 0, "output" => output}] = cms["commands"]
    assert output =~ "mix cms.new"
    assert [%{"command" => "mix", "args" => ["help", "cms.new"]}] = cms["commands"]
    refute File.exists?(Path.join(ctx.bin, "cms"))
    assert {:ok, ^result} = Setup.status(ctx.opts)
  end

  test "missing Just blocks setup before a generated recipe needs it", ctx do
    File.rm!(Path.join(ctx.bin, "just"))

    assert {:ok, result} = Setup.check_prerequisites(ctx.opts)
    refute Setup.prerequisites_passed?(result)
    just = Enum.find(result["steps"], &(&1["key"] == "just"))
    assert just["state"] == "errored"

    assert [%{"command" => "just", "args" => ["--version"], "exit_status" => nil}] =
             just["commands"]
  end

  test "a missing executable and nonzero exit are recorded as failures", ctx do
    File.rm!(Path.join(ctx.bin, "vibium"))

    File.write!(
      Path.join(ctx.bin, "mix"),
      "#!/bin/sh\nprintf 'runtime unavailable' >&2\nexit 126\n"
    )

    assert {:ok, result} = Setup.check_prerequisites(ctx.opts)
    refute Setup.prerequisites_passed?(result)
    assert result["state"] == "errored"
    cms = Enum.find(result["steps"], &(&1["key"] == "cms"))
    vibium = Enum.find(result["steps"], &(&1["key"] == "vibium"))
    assert cms["state"] == "errored"
    assert cms["error"] =~ "runtime unavailable"
    assert [%{"exit_status" => 126}] = cms["commands"]
    assert vibium["state"] == "errored"
    assert [%{"exit_status" => nil}] = vibium["commands"]
    assert {:ok, ^result} = Setup.status(ctx.opts)
  end

  test "empty successful pgvector query is not a passing extension check", ctx do
    File.write!(Path.join(ctx.bin, "psql"), "#!/bin/sh\nexit 0\n")
    assert {:ok, result} = Setup.check_prerequisites(ctx.opts)
    pgvector = Enum.find(result["steps"], &(&1["key"] == "pgvector"))
    assert pgvector["state"] == "errored"
    assert pgvector["error"] =~ "pgvector is not installed"
    refute Setup.prerequisites_passed?(result)
  end

  test "corrupt state is preserved rather than silently starting over", ctx do
    File.mkdir_p!(ctx.opts[:directory])
    pointer = Path.join(ctx.opts[:directory], "current.json")
    File.write!(pointer, "invalid json")
    assert {:error, :invalid_setup_pointer} = Setup.check_prerequisites(ctx.opts)
    assert {:error, :invalid_setup_pointer} = Setup.new_run(ctx.opts)
    assert File.read!(pointer) == "invalid json"
    assert File.read!(ctx.log) == ""
  end

  test "project generation requires successful recorded prerequisites", ctx do
    target = Path.join(ctx.root, "new_project")

    assert {:error, :prerequisites_not_checked} =
             Setup.generate_project(target, "new_project", ctx.opts)

    refute File.exists?(target)
    assert File.read!(ctx.log) == ""

    File.rm!(Path.join(ctx.bin, "vibium"))
    assert {:ok, _} = Setup.check_prerequisites(ctx.opts)
    recorded = File.read!(ctx.log)

    assert {:error, :prerequisites_failed} =
             Setup.generate_project(target, "new_project", ctx.opts)

    refute File.exists?(target)
    assert File.read!(ctx.log) == recorded
  end

  test "a failed project operation is recorded and never silently retried", ctx do
    assert {:ok, _} = Setup.check_prerequisites(ctx.opts)
    marker = Path.join(ctx.root, "existing.txt")
    File.write!(marker, "preserve")

    assert {:error, {:already_exists, _}} =
             Setup.generate_project(ctx.root, "selected_app", ctx.opts)

    assert {:ok, failed} = Setup.status(ctx.opts)
    operation = failed["operations"]["generate"]
    assert operation["state"] == "errored"
    assert operation["error"] =~ "already_exists"
    assert is_binary(operation["started_at"])
    assert is_binary(operation["finished_at"])

    assert {:error, :operation_already_attempted_start_new_run} =
             Setup.generate_project(ctx.root, "selected_app", ctx.opts)

    assert {:ok, ^failed} = Setup.status(ctx.opts)
    assert File.read!(marker) == "preserve"
  end

  test "successful generation is recorded and reopening never generates again", ctx do
    target = Path.join(ctx.root, "generated_project")
    executable = Path.join(ctx.bin, "mix")

    File.write!(executable, """
    #!/bin/sh
    if [ \"$*\" = \"help cms.new\" ]; then printf 'mix cms.new\\n'; exit 0; fi
    printf 'generate\\n' >> '#{ctx.log}'
    /bin/mkdir -p "$2" || exit 1
    printf '%s\\n' 'defmodule Generated.MixProject do' '  use Mix.Project' 'end' > "$2/mix.exs"
    """)

    File.chmod!(executable, 0o700)

    assert {:ok, _} = Setup.check_prerequisites(ctx.opts)
    assert {:ok, generated} = Setup.generate_project(target, "generated_project", ctx.opts)
    assert generated["operations"]["generate"]["state"] == "done"
    assert generated["operations"]["generate"]["result"] == target
    assert File.regular?(Path.join(target, "mix.exs"))
    recorded_commands = File.read!(ctx.log)

    assert {:ok, ^generated} = Setup.generate_project(target, "generated_project", ctx.opts)
    assert {:ok, ^generated} = Setup.status(ctx.opts)
    assert File.read!(ctx.log) == recorded_commands
  end

  test "an unavailable generator records a finished failure", ctx do
    assert {:ok, _} = Setup.check_prerequisites(ctx.opts)
    File.rm!(Path.join(ctx.bin, "mix"))
    target = Path.join(ctx.root, "generated_project")

    assert {:error, {:generator_unavailable, message}} =
             Setup.generate_project(target, "generated_project", ctx.opts)

    assert is_binary(message)
    assert {:ok, result} = Setup.status(ctx.opts)
    operation = result["operations"]["generate"]
    assert operation["state"] == "errored"
    assert is_binary(operation["finished_at"])
    assert operation["error"] =~ "generator_unavailable"
    refute File.exists?(target)
  end

  test "rejecting a non-Elixir directory leaves the connection attempt available", ctx do
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    identity = %{project_id: "project", working_copy_id: "copy", app: "selected_app"}

    assert {:error, {:invalid_elixir_project, _, :enoent}} =
             Setup.connect_project(ctx.root, identity, ctx.opts)

    assert {:ok, ^checked} = Setup.status(ctx.opts)
    refute File.exists?(Path.join(ctx.root, ".cms_harness.json"))
  end

  test "a refused connection records a finished failure without rerunning checks", ctx do
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    commands = File.read!(ctx.log)

    File.write!(
      Path.join(ctx.root, "mix.exs"),
      "defmodule Refused.MixProject do\n  use Mix.Project\nend\n"
    )

    :ok =
      CmsHarness.HarnessConfig.write(ctx.root, %{
        project_id: "recorded-project",
        working_copy_id: "recorded-copy",
        root: ctx.root
      })

    identity = %{
      project_id: "different-project",
      working_copy_id: "recorded-copy",
      app: "refused"
    }

    assert {:error, {:project_identity_conflict, "recorded-project"}} =
             Setup.connect_project(ctx.root, identity, ctx.opts)

    assert {:ok, failed} = Setup.status(ctx.opts)
    operation = failed["operations"]["connect"]
    assert operation["state"] == "errored"
    assert operation["error"] =~ "project_identity_conflict"
    assert {:ok, _, _} = DateTime.from_iso8601(operation["finished_at"])
    assert failed["steps"] == checked["steps"]
    assert {:ok, ^failed} = Setup.refresh_connection(ctx.opts)
    assert File.read!(ctx.log) == commands
  end

  @tag timeout: 30_000
  test "pending connection stays unfinished until explicit refresh observes a live connection",
       ctx do
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    commands = File.read!(ctx.log)
    restore_path(ctx.original_path)
    previous_id = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    on_exit(fn -> restore_project_id(previous_id) end)

    CmsHarnessTest.FakeServer.start(hold_joins: true)
    project = CmsHarnessTest.Projects.project_dir()
    on_exit(fn -> CmsHarnessTest.Projects.stop_project(project.root) end)

    File.write!(
      Path.join(project.root, "mix.exs"),
      "defmodule Pending.MixProject do\n  use Mix.Project\n  def project, do: [app: :pending, version: \"0.1.0\", deps: []]\nend\n"
    )

    identity = %{project_id: project.id, working_copy_id: project.working_copy_id, app: "pending"}

    assert {:ok, pending} = Setup.connect_project(project.root, identity, ctx.opts)
    operation = pending["operations"]["connect"]
    assert operation["state"] == "pending"
    assert operation["finished_at"] == nil
    assert operation["result"]["connection_state"] == "pending"
    assert operation["result"]["connected"] == false
    assert {:ok, _, _} = DateTime.from_iso8601(operation["result"]["observed_at"])
    bytes = File.read!(pending["results_path"])
    assert {:ok, ^pending} = Setup.status(ctx.opts)
    assert {:ok, ^pending} = Setup.refresh_connection(ctx.opts)
    assert {:error, :project_not_connected} = Setup.handoff(ctx.opts)
    assert File.read!(pending["results_path"]) == bytes

    CmsHarnessTest.Projects.stop_project(project.root)
    CmsHarnessTest.FakeServer.hold_joins(false)
    assert {:ok, _} = CmsHarness.Projects.ensure_started(project.root)
    assert %{connected: true} = CmsHarness.Setup.Connection.observe(project.root)
    assert {:ok, ^pending} = Setup.status(ctx.opts)
    assert {:ok, completed} = Setup.refresh_connection(ctx.opts)
    finished = completed["operations"]["connect"]
    assert finished["state"] == "done"
    assert finished["result"]["connected"] == true
    assert finished["result"]["connection_state"] == "connected"
    assert finished["finished_at"] == finished["result"]["observed_at"]
    assert finished["started_at"] == operation["started_at"]
    assert completed["steps"] == checked["steps"]
    assert completed["run_id"] == checked["run_id"]
    assert File.read!(ctx.log) == commands
    assert {:ok, handoff} = Setup.handoff(ctx.opts)
    assert handoff.project_id == project.id
    completed_bytes = File.read!(completed["results_path"])
    assert {:ok, ^completed} = Setup.refresh_connection(ctx.opts)
    assert File.read!(completed["results_path"]) == completed_bytes
  end

  @tag timeout: 30_000
  test "retrying a pending connection restarts the same checkout and retries dev setup", ctx do
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    restore_path(ctx.original_path)
    previous_id = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    on_exit(fn -> restore_project_id(previous_id) end)
    CmsHarnessTest.FakeServer.start(hold_joins: true)
    project = CmsHarnessTest.Projects.project_dir()
    on_exit(fn -> CmsHarnessTest.Projects.stop_project(project.root) end)

    File.write!(
      Path.join(project.root, "mix.exs"),
      "defmodule Retry.MixProject do\n use Mix.Project\n def project, do: [app: :retry, version: \"0.1.0\", deps: []]\nend\n"
    )

    identity = %{project_id: project.id, working_copy_id: project.working_copy_id, app: "retry"}
    assert {:ok, pending} = Setup.connect_project(project.root, identity, ctx.opts)
    assert pending["operations"]["connect"]["state"] == "pending"
    CmsHarnessTest.Projects.stop_project(project.root)
    CmsHarnessTest.FakeServer.hold_joins(false)

    File.write!(
      Path.join(project.root, "justfile"),
      "dev-setup:\n    printf done > .setup-done\n"
    )

    assert {:ok, completed} = Setup.connect_project(project.root, identity, ctx.opts)
    assert completed["operations"]["connect"]["state"] == "done"

    assert completed["operations"]["connect"]["result"]["working_copy_id"] ==
             project.working_copy_id

    assert completed["operations"]["dev_setup"]["state"] == "done"
    assert File.read!(Path.join(project.root, ".setup-done")) == "done"
    assert completed["run_id"] == checked["run_id"]
    assert completed["steps"] == checked["steps"]
  end

  defp restore_project_id(nil), do: System.delete_env("CMS_PROJECT_ID")
  defp restore_project_id(value), do: System.put_env("CMS_PROJECT_ID", value)

  test "handoff requires a recorded project and never reruns checks", ctx do
    assert {:error, :prerequisites_not_checked} = Setup.handoff(ctx.opts)
    refute File.exists?(ctx.opts[:directory])
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    bytes = File.read!(checked["results_path"])
    commands = File.read!(ctx.log)
    assert {:error, :project_not_connected} = Setup.handoff(ctx.opts)
    assert File.read!(checked["results_path"]) == bytes
    assert File.read!(ctx.log) == commands
  end

  test "handoff returns the recorded project and preserves setup history", ctx do
    assert {:ok, checked} = Setup.check_prerequisites(ctx.opts)
    root = Path.join(ctx.root, "connected_project")

    connected =
      Map.put(checked, "operations", %{
        "connect" => %{
          "state" => "done",
          "result" => %{
            "id" => "project-id",
            "working_copy_id" => "copy-id",
            "root" => root,
            "connected" => true
          }
        }
      })

    assert :ok = CmsHarness.Setup.Store.save(ctx.opts[:directory], connected)
    bytes = File.read!(connected["results_path"])
    commands = File.read!(ctx.log)

    assert {:ok, handoff} = Setup.handoff(ctx.opts)

    assert handoff == %{
             project_id: "project-id",
             working_copy_id: "copy-id",
             root: root,
             results_path: connected["results_path"],
             run_id: connected["run_id"]
           }

    assert File.read!(connected["results_path"]) == bytes
    assert File.read!(ctx.log) == commands
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
