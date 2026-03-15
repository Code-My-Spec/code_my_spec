defmodule CodeMySpec.Issues.ProjectorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.Projector
  alias CodeMySpec.Paths

  @moduletag :unit

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "projector_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    env = %Environment{type: :local, cwd: tmp_dir}

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{env: env, tmp_dir: tmp_dir}
  end

  defp build_issue(overrides \\ %{}) do
    Map.merge(
      %Issue{
        id: Ecto.UUID.generate(),
        title: "Test Issue",
        severity: :high,
        scope: :app,
        description: "A test issue",
        status: :incoming,
        story_id: 1,
        project_id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp incoming_dir(tmp_dir), do: Path.join(tmp_dir, Paths.issues_incoming_dir())
  defp accepted_dir(tmp_dir), do: Path.join(tmp_dir, Paths.issues_accepted_dir())

  describe "project_issue/2" do
    test "writes incoming issue to incoming/ directory", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{status: :incoming})

      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      expected_path = Path.join(incoming_dir(tmp_dir), filename)
      assert File.exists?(expected_path)
    end

    test "writes accepted issue to accepted/ directory", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{status: :accepted})

      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      expected_path = Path.join(accepted_dir(tmp_dir), filename)
      assert File.exists?(expected_path)
    end

    test "writes resolved issue to accepted/ with Resolution section", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      issue = build_issue(%{status: :resolved, resolution: "Fixed in PR #42"})

      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      expected_path = Path.join(accepted_dir(tmp_dir), filename)
      assert File.exists?(expected_path)

      content = File.read!(expected_path)
      assert content =~ "## Resolution"
      assert content =~ "Fixed in PR #42"
    end

    test "does not write dismissed issues", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{status: :dismissed, resolution: "Not a real issue"})

      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      incoming_path = Path.join(incoming_dir(tmp_dir), filename)
      accepted_path = Path.join(accepted_dir(tmp_dir), filename)

      refute File.exists?(incoming_path)
      refute File.exists?(accepted_path)
    end

    test "removes stale file from old directory on status change", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{status: :incoming})

      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      assert File.exists?(Path.join(incoming_dir(tmp_dir), filename))

      accepted_issue = Map.put(issue, :status, :accepted)
      Projector.project_issue(env, accepted_issue)

      refute File.exists?(Path.join(incoming_dir(tmp_dir), filename))
      assert File.exists?(Path.join(accepted_dir(tmp_dir), filename))
    end

    test "generates correct filename slug from title", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{title: "My Test Issue!", story_id: 5, status: :incoming})

      Projector.project_issue(env, issue)

      expected_path = Path.join(incoming_dir(tmp_dir), "qa-5-my_test_issue.md")
      assert File.exists?(expected_path)
    end

    test "uses braindump prefix when story_id is nil", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{title: "Braindump Issue", story_id: nil, status: :incoming})

      Projector.project_issue(env, issue)

      expected_path = Path.join(incoming_dir(tmp_dir), "braindump-braindump_issue.md")
      assert File.exists?(expected_path)
    end
  end

  describe "project_all/2" do
    test "projects all active issues", %{env: env, tmp_dir: tmp_dir} do
      incoming = build_issue(%{title: "Incoming One", status: :incoming, story_id: 1})
      accepted = build_issue(%{title: "Accepted One", status: :accepted, story_id: 2})
      resolved = build_issue(%{title: "Resolved One", status: :resolved, story_id: 3, resolution: "Done"})

      Projector.project_all(env, [incoming, accepted, resolved])

      assert File.exists?(Path.join(incoming_dir(tmp_dir), Projector.build_filename(incoming)))
      assert File.exists?(Path.join(accepted_dir(tmp_dir), Projector.build_filename(accepted)))
      assert File.exists?(Path.join(accepted_dir(tmp_dir), Projector.build_filename(resolved)))
    end

    test "clears stale files from previous projections", %{env: env, tmp_dir: tmp_dir} do
      stale_dir = incoming_dir(tmp_dir)
      File.mkdir_p!(stale_dir)
      stale_file = Path.join(stale_dir, "qa-99-stale_issue.md")
      File.write!(stale_file, "old content")

      issue = build_issue(%{title: "New Issue", status: :incoming, story_id: 10})

      Projector.project_all(env, [issue])

      refute File.exists?(stale_file)
      assert File.exists?(Path.join(stale_dir, Projector.build_filename(issue)))
    end

    test "skips dismissed issues", %{env: env, tmp_dir: tmp_dir} do
      dismissed = build_issue(%{title: "Dismissed Issue", status: :dismissed, story_id: 7, resolution: "Ignore"})
      active = build_issue(%{title: "Active Issue", status: :incoming, story_id: 8})

      Projector.project_all(env, [dismissed, active])

      refute File.exists?(Path.join(incoming_dir(tmp_dir), Projector.build_filename(dismissed)))
      refute File.exists?(Path.join(accepted_dir(tmp_dir), Projector.build_filename(dismissed)))
      assert File.exists?(Path.join(incoming_dir(tmp_dir), Projector.build_filename(active)))
    end

    test "creates directories if missing", %{env: env, tmp_dir: tmp_dir} do
      refute File.exists?(incoming_dir(tmp_dir))
      refute File.exists?(accepted_dir(tmp_dir))

      Projector.project_all(env, [])

      assert File.exists?(incoming_dir(tmp_dir))
      assert File.exists?(accepted_dir(tmp_dir))
    end

    test "is idempotent", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{title: "Stable Issue", status: :incoming, story_id: 1})

      Projector.project_all(env, [issue])
      Projector.project_all(env, [issue])

      filename = Projector.build_filename(issue)
      expected_path = Path.join(incoming_dir(tmp_dir), filename)
      assert File.exists?(expected_path)

      files = File.ls!(incoming_dir(tmp_dir))
      assert Enum.count(files, &(&1 == filename)) == 1
    end
  end

  describe "remove_projection/2" do
    test "removes file from incoming directory", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{status: :incoming})
      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      assert File.exists?(Path.join(incoming_dir(tmp_dir), filename))

      Projector.remove_projection(env, issue)

      refute File.exists?(Path.join(incoming_dir(tmp_dir), filename))
    end

    test "removes file from accepted directory", %{env: env, tmp_dir: tmp_dir} do
      issue = build_issue(%{status: :accepted})
      Projector.project_issue(env, issue)

      filename = Projector.build_filename(issue)
      assert File.exists?(Path.join(accepted_dir(tmp_dir), filename))

      Projector.remove_projection(env, issue)

      refute File.exists?(Path.join(accepted_dir(tmp_dir), filename))
    end

    test "succeeds even if file doesn't exist", %{env: env} do
      issue = build_issue(%{title: "Nonexistent Issue", story_id: 999})

      result = Projector.remove_projection(env, issue)

      assert result == :ok
    end
  end

  describe "build_filename/1" do
    test "generates qa- prefix with story_id" do
      issue = build_issue(%{title: "My Issue", story_id: 42})

      filename = Projector.build_filename(issue)

      assert String.starts_with?(filename, "qa-42-")
    end

    test "generates braindump- prefix without story_id" do
      issue = build_issue(%{title: "My Issue", story_id: nil})

      filename = Projector.build_filename(issue)

      assert String.starts_with?(filename, "braindump-")
    end

    test "slugifies title correctly" do
      issue = build_issue(%{title: "Hello World! It's a Test.", story_id: 1})

      filename = Projector.build_filename(issue)

      assert filename == "qa-1-hello_world_it_s_a_test.md"
    end

    test "truncates long titles" do
      long_title = String.duplicate("a", 60)
      issue = build_issue(%{title: long_title, story_id: 1})

      filename = Projector.build_filename(issue)

      slug = filename |> String.replace_prefix("qa-1-", "") |> String.replace_suffix(".md", "")
      assert String.length(slug) <= 41
    end
  end

  describe "build_content/1" do
    test "includes all required sections" do
      issue = build_issue(%{
        title: "Missing Auth Check",
        severity: :high,
        scope: :app,
        description: "Endpoint has no auth guard",
        story_id: 3
      })

      content = Projector.build_content(issue)

      assert content =~ "# Missing Auth Check"
      assert content =~ "## Status"
      assert content =~ "incoming"
      assert content =~ "## Severity"
      assert content =~ "## Scope"
      assert content =~ "## Description"
      assert content =~ "Endpoint has no auth guard"
      assert content =~ "## Source"
    end

    test "appends Resolution section when status is :resolved" do
      issue = build_issue(%{
        status: :resolved,
        resolution: "Applied auth plug in router"
      })

      content = Projector.build_content(issue)

      assert content =~ "## Resolution"
      assert content =~ "Applied auth plug in router"
    end

    test "omits Resolution section when not resolved" do
      issue = build_issue(%{status: :incoming})

      content = Projector.build_content(issue)

      refute content =~ "## Resolution"
    end

    test "formats source as story reference when story_id present" do
      issue = build_issue(%{story_id: 7, source_path: nil})

      content = Projector.build_content(issue)

      assert content =~ "QA Story 7"
    end
  end
end
