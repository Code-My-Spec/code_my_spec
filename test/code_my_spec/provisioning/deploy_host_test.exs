defmodule CodeMySpec.Provisioning.DeployHostTest do
  @moduledoc """
  A deploy answers on its own environment's hostname.

  The step read the project's domain regardless of which environment it was
  deploying, so a UAT deploy was handed production's hostname. It travelled:
  into `CMS_DEPLOY_HOST`, from there into the container's `PHX_HOST` and
  kamal's `proxy.host`, and finally into the health check — which probed
  production's address after deploying to UAT's box, found nothing listening,
  and reported `econnrefused` for a deploy that had otherwise succeeded.

  The failure looked like a broken deploy. It was a deploy to the right
  machine, described to itself as the wrong site.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.EnvironmentRepository

  @domain "deploy-host.example.com"

  setup do
    scope = full_scope_fixture()

    # Before the first `list/1`: hosts are derived from the domain when the
    # environments are seeded, so a project given its domain afterwards seeds
    # two environments with no hosts at all.
    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @domain})

    scope = %{scope | active_project: project}

    # Seeds `prod` on the apex and `uat` on a subdomain of it, which is the
    # rule this is about.
    EnvironmentRepository.list(scope)

    {:ok, scope: scope}
  end

  test "each environment carries its own host, and only production takes the apex", ctx do
    hosts =
      ctx.scope
      |> EnvironmentRepository.list()
      |> Map.new(&{&1.name, &1.host})

    assert hosts["prod"] == @domain
    assert hosts["uat"] == "uat.#{@domain}"

    refute hosts["uat"] == hosts["prod"],
           "both environments answer on one hostname, so a UAT deploy would " <>
             "describe itself as production"
  end

  test "an environment given no domain has no host to deploy to", ctx do
    # Hosts come from the domain at seed time. A project that had none seeds
    # environments with none, and `environment_host/2` has nothing to return —
    # which is why the deploy step still falls back to the project domain
    # rather than deploying to `nil`.
    bare = full_scope_fixture()

    assert bare.active_project.domain in [nil, ""]

    hosts = bare |> EnvironmentRepository.list() |> Enum.map(& &1.host)

    assert Enum.all?(hosts, &is_nil/1),
           "hosts were invented for a project with no domain: #{inspect(hosts)}"

    # And the project that does have one is unaffected by its neighbour.
    assert ctx.scope |> EnvironmentRepository.get("uat") |> Map.fetch!(:host) ==
             "uat.#{@domain}"
  end
end
