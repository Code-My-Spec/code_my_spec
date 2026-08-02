defmodule CodeMySpecWeb.PortableRouteParityTest do
  @moduledoc """
  The portable LiveViews in `CodeMySpecWeb` are mounted by both routers, and
  they build links with plain `~p` literals. That only works because both
  routers declare the *same path shape* for every portable surface.

  Compile-time verification only guards one side: `~p` in those views is
  checked against `CodeMySpecWeb.Router`, so a route renamed there is a build
  error. Nothing checks the local router. Without this test, dropping or
  renaming a local route produces links that compile fine and 404 at runtime,
  on the app the developer is least likely to be looking at.
  """
  use ExUnit.Case, async: true

  @portable_prefix "/app/projects/:project_id/"

  defp portable_routes(router) do
    router.__routes__()
    |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.starts_with?(&1, @portable_prefix))
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "both routers mount every portable surface at the same path" do
    cloud = portable_routes(CodeMySpecWeb.Router)
    local = portable_routes(CodeMySpecLocalWeb.Router)

    assert cloud != [], """
    No portable routes found in CodeMySpecWeb.Router under #{@portable_prefix}.
    Either the prefix changed or the portable mount was removed — this test is
    the only guard on the shared-path invariant, so fix it rather than delete it.
    """

    assert cloud == local, """
    The two routers disagree about the portable surface. Shared LiveViews build
    links with `~p` literals verified only against CodeMySpecWeb.Router, so a
    mismatch here means correct-looking links that 404 on one of the apps.

    only in CodeMySpecWeb.Router:      #{inspect(cloud -- local, pretty: true)}
    only in CodeMySpecLocalWeb.Router: #{inspect(local -- cloud, pretty: true)}
    """
  end

  test "both routers dispatch each portable path to the same LiveView" do
    views = fn router ->
      router.__routes__()
      |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
      |> Enum.filter(&String.starts_with?(&1.path, @portable_prefix))
      |> Map.new(&{&1.path, &1.metadata.phoenix_live_view |> elem(0)})
    end

    cloud = views.(CodeMySpecWeb.Router)
    local = views.(CodeMySpecLocalWeb.Router)

    mismatched =
      for {path, cloud_view} <- cloud,
          local_view = Map.get(local, path),
          local_view != cloud_view,
          do: {path, cloud: cloud_view, local: local_view}

    assert mismatched == [], """
    Same path, different LiveView. Both mounts must resolve to the one shared
    module, otherwise the apps have silently forked.

    #{inspect(mismatched, pretty: true)}
    """
  end
end
