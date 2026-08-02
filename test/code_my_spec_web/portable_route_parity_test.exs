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

  test "every path the local app serves also exists on the cloud" do
    cloud = portable_routes(CodeMySpecWeb.Router)
    local = portable_routes(CodeMySpecLocalWeb.Router)

    assert local != [], """
    No portable routes found in CodeMySpecLocalWeb.Router under
    #{@portable_prefix}. Either the prefix changed or the portable mount was
    removed — this test is the only guard on the shared-path invariant, so fix
    it rather than delete it.
    """

    # Subset, not equality: the local router is the record of what has been
    # migrated, while the cloud additionally serves project-scoped surfaces
    # that have no local counterpart (mail, inbox, mailboxes). What must never
    # happen is the local app serving a path the cloud doesn't — the shared
    # views' `~p` literals are only verified against the cloud router, so that
    # direction is the one nothing else would catch.
    missing = local -- cloud

    assert missing == [], """
    CodeMySpecLocalWeb.Router serves paths CodeMySpecWeb.Router doesn't. Shared
    LiveViews build links verified only against the cloud router, so these are
    links that look correct and 404:

    #{inspect(missing, pretty: true)}
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
