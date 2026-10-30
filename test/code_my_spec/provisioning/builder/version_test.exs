defmodule CodeMySpec.Provisioning.Builder.VersionTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Builder.Version

  setup do
    repo = CodeMySpec.TempFile.dir("cms-builder-version")
    File.mkdir_p!(repo)
    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "-q", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "builder@example.com"])
    {_, 0} = git.(["config", "user.name", "Builder"])
    File.write!(Path.join(repo, "source"), "first")
    {_, 0} = git.(["add", "source"])
    {_, 0} = git.(["commit", "-q", "-m", "first"])
    {first, 0} = git.(["rev-parse", "HEAD"])
    first = String.trim(first)
    {_, 0} = git.(["tag", "v2.4.6", first])

    File.write!(Path.join(repo, "source"), "second")
    {_, 0} = git.(["commit", "-q", "-am", "second"])
    {second, 0} = git.(["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf(repo) end)
    %{repo: repo, first: first, second: String.trim(second)}
  end

  # mix.exs takes CMS_VERSION verbatim and Mix refuses anything that is not a
  # Version: "v2.0.719" failed the 2026-10-30 prod image build at `mix compile`.
  test "uses the release tag on the requested commit even after HEAD moves, without its v", ctx do
    assert {:ok, "2.4.6"} = Version.for_ref(String.slice(ctx.first, 0, 12), version_cd: ctx.repo)
  end

  test "names an untagged commit in build metadata", ctx do
    assert {:ok, "0.0.0+g" <> short} =
             Version.for_ref(String.slice(ctx.second, 0, 12), version_cd: ctx.repo)

    assert short == String.slice(ctx.second, 0, 12)
  end

  test "every version it answers is one Mix accepts", ctx do
    for commit <- [ctx.first, ctx.second] do
      assert {:ok, version} = Version.for_ref(String.slice(commit, 0, 12), version_cd: ctx.repo)
      assert {:ok, _} = Elixir.Version.parse(version)
    end
  end

  test "refuses an unknown commit with a plain message", ctx do
    assert {:error, "cannot build image: could not determine the commit being built"} =
             Version.for_ref("000000000000", version_cd: ctx.repo)
  end

  test "looks up the requested commit and its release tag through GitHub" do
    sha = "abc123" <> String.duplicate("0", 34)

    responses = %{
      {"/repos/acme/app/commits/abc123", nil} => %{sha: sha},
      {"/repos/acme/app/tags", "1"} => [%{name: "v2.4.6", commit: %{sha: sha}}],
      {"/repos/acme/app/tags", "2"} => []
    }

    Req.Test.stub(Version, fn conn ->
      key = {conn.request_path, Plug.Conn.Query.decode(conn.query_string)["page"]}
      Req.Test.json(conn, Map.fetch!(responses, key))
    end)

    assert {:ok, "2.4.6"} =
             Version.for_ref("abc123", github_repo: "acme/app", github_token: "test-token")
  end
end
