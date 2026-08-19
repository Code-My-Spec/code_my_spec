defmodule CodeMySpec.Files.AcronymOwnershipTest do
  @moduledoc """
  A component whose name carries a run of two or more capitals still owns its
  files.

  `Macro.underscore/1` destroys capitalization and `Macro.camelize/1` cannot put
  it back, so every path → module derivation is a guess that fails on exactly
  those names:

      CodeMySpec.Git.CLI        -> code_my_spec/git/cli         -> ...Git.Cli        ✗
      CodeMySpec.Git.URLParser  -> code_my_spec/git/url_parser  -> ...Git.UrlParser  ✗
      CodeMySpec.HTMLRenderer   -> code_my_spec/html_renderer   -> ...HtmlRenderer   ✗
      CodeMySpec.JSONAPI        -> code_my_spec/jsonapi         -> ...Jsonapi        ✗
      CodeMySpec.OAuth.Client   -> code_my_spec/o_auth/client   -> ...OAuth.Client   ✓
      Foo.Bar                   -> foo/bar                      -> Foo.Bar           ✓

  It is not "acronyms break" — `OAuth` survives, having only one capital run,
  which is why the failures look arbitrary until they are lined up. `JSONAPI` is
  unrecoverable in principle: `jsonapi` has lost the word boundary.

  So ownership resolves by looking the *path* up against components projected
  forward into their conventional paths, which is exact. This asserts that from
  a clean slate — no `ComponentSync` backfill involved — because the backfill
  masked the bug for years by repairing it after the fact, on every scan, in a
  fight neither side won (`d698ab0e`).
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components.ConventionalPaths
  alias CodeMySpec.Files
  alias CodeMySpec.Files.Scanner
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    {:ok, scope: full_scope_fixture()}
  end

  defp observation(path, role) do
    %{path: path, role: role, mtime: ~U[2026-07-28 10:00:00.000000Z], size: 1, fingerprint: path}
  end

  defp resolve(scope, entries), do: Scanner.resolve_owners(entries, Files.read_model(scope))

  for {module, impl, test} <- [
        {"Demo.CLI", "lib/demo/cli.ex", "test/demo/cli_test.exs"},
        {"Demo.URLParser", "lib/demo/url_parser.ex", "test/demo/url_parser_test.exs"},
        {"Demo.HTMLRenderer", "lib/demo/html_renderer.ex", "test/demo/html_renderer_test.exs"},
        {"Demo.OAuth", "lib/demo/o_auth.ex", "test/demo/o_auth_test.exs"}
      ] do
    test "#{module} owns its implementation and its test", %{scope: scope} do
      component =
        CodeMySpec.ComponentsFixtures.component_fixture(scope, %{
          module_name: unquote(module),
          name: unquote(module)
        })

      resolved =
        resolve(scope, [
          observation(unquote(impl), :implementation),
          observation(unquote(test), :test)
        ])

      assert Enum.map(resolved, & &1.component_id) == [component.id, component.id], """
      #{unquote(module)} did not own its own files.

      Deriving the module from the path camelizes #{unquote(impl)} back to
      something that is not #{unquote(module)}, so the lookup missed. The path
      index exists precisely so that derivation is not the thing being asked.
      """
    end
  end

  test "the conventional paths round-trip from the module name" do
    paths = ConventionalPaths.for_component(%{module_name: "Demo.CLI", type: "module"})

    assert "lib/demo/cli.ex" in paths
    assert "test/demo/cli_test.exs" in paths

    assert Enum.any?(paths, &String.ends_with?(&1, "demo/cli.spec.md")),
           "the spec path is what `require_specs` gates on"
  end

  test "a liveview keeps its Phoenix directory", %{scope: scope} do
    # `source_path_for_type`'s rule, now shared rather than duplicated: the two
    # copies of it were what allowed the guess and the claim to disagree.
    component =
      CodeMySpec.ComponentsFixtures.component_fixture(scope, %{
        module_name: "DemoWeb.ThingLive.Show",
        name: "Show",
        type: "liveview"
      })

    [resolved] =
      resolve(scope, [observation("lib/demo_web/live/thing_live/show.ex", :implementation)])

    assert resolved.component_id == component.id,
           "a LiveView lives under live/, and the index has to project that or " <>
             "every LiveView is unowned"
  end
end
