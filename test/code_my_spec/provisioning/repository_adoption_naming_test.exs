defmodule CodeMySpec.Provisioning.RepositoryAdoptionNamingTest do
  @moduledoc """
  Confirmed live against cleaner_crm: a project's already-correct `code_repo`
  (`git@github.com:Code-My-Spec/cleaner_crm.git`, an org, underscored to match
  its own `mix.exs` :app atom) was not recognized as the repository
  `Steps.run(:repository, ...)` would use, because `ours?/2` compared it
  literally against `Repository.default_name/1`'s always-hyphenated slug
  ("cleaner-crm" != "cleaner_crm") and, even once `adopt: true` was forced,
  `Repository.ensure/3` still looked under the caller's own authenticated
  GitHub login and the hyphenated name rather than the org and the real name
  — finding nothing there and creating a second, empty repository.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.GitHub
  alias CodeMySpec.Provisioning.Steps

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    _ = github_integration_fixture(scope.user)

    %{env: Environment.new(:local, tmp), scope: scope}
  end

  defp stub_github(fun), do: Req.Test.stub(GitHub, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  test "adopts an org-owned, underscore-named repository instead of creating a personal one",
       ctx do
    repo = %{
      "name" => "cleaner_crm",
      "owner" => %{"login" => "Code-My-Spec"},
      "clone_url" => "https://github.com/Code-My-Spec/cleaner_crm.git"
    }

    stub_github(fn
      %{method: "GET", request_path: "/repos/Code-My-Spec/cleaner_crm"} = conn ->
        json(conn, 200, repo)

      %{method: "GET"} = conn ->
        flunk("looked up the wrong (owner, name) instead of the recorded repository")
        conn

      %{method: "POST"} = conn ->
        flunk("created a repository when the recorded one should have been adopted")
        conn
    end)

    scope = %{
      ctx.scope
      | active_project: %{
          name: "Cleaner CRM",
          code_repo: "git@github.com:Code-My-Spec/cleaner_crm.git"
        },
        environment: ctx.env
    }

    # The push itself is not this test's concern — no real remote exists at
    # `tmp` — only that the lookup landed on the repository already recorded,
    # not one re-derived from the authenticated login and a hyphenated slug.
    result = Steps.run(:repository, scope, [])

    refute match?({:error, "GitHub is not connected" <> _}, result)
    refute match?({:paused, "A repository named" <> _}, result)
  end
end
