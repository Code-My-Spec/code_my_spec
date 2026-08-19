defmodule CodeMySpec.Components.ConventionalPaths do
  @moduledoc """
  Where a component's files live, derived from its module name.

  ## Only one direction of this is well-defined

  `Macro.underscore/1` destroys capitalization, and `Macro.camelize/1` cannot
  put it back:

      CodeMySpec.Git.CLI        -> code_my_spec/git/cli         -> ...Git.Cli        ✗
      CodeMySpec.Git.URLParser  -> code_my_spec/git/url_parser  -> ...Git.UrlParser  ✗
      CodeMySpec.HTMLRenderer   -> code_my_spec/html_renderer   -> ...HtmlRenderer   ✗
      CodeMySpec.JSONAPI        -> code_my_spec/jsonapi         -> ...Jsonapi        ✗
      CodeMySpec.OAuth.Client   -> code_my_spec/o_auth/client   -> ...OAuth.Client   ✓
      Foo.Bar                   -> foo/bar                      -> Foo.Bar           ✓

  It is not "acronyms break". It is **runs of two or more capitals** break —
  `OAuth` survives because it has only one, which is why the failures look
  arbitrary until you line them up. `JSONAPI` is the worst case: `jsonapi` has
  lost the word boundary, so no rule could recover it.

  So nothing here guesses a module from a path. Module names are known — they
  are a column — and this projects them forward, which is exact. Callers that
  need "which component owns this file" build a map keyed by these paths and
  look the path up.

  That is the same move `story_by_spec_path` already made for spex files: a
  criterion records which file is its spex, so ownership became a lookup instead
  of a number parsed out of a directory name.

  ## One home, because two would drift

  `ComponentSync.backfill_file_owners/2` claims files by these paths, and
  `Files.read_model/1` indexes components by them. Those two must agree, and a
  pair that must agree with nothing linking them is how most of this system's
  quiet bugs have started — most recently `d698ab0e`, where a path-derived guess
  wrote `nil` over what the path-pattern claim had just set, on every scan
  forever.
  """

  alias CodeMySpec.Paths

  @doc """
  Every path this component conventionally owns.

  Spec and design review under `.code_my_spec/spec/`, implementation under
  `lib/`, test under `test/`. A component need not have all of them; these are
  the paths that *would* be its, which is what makes them usable as an index.
  """
  @spec for_component(%{module_name: String.t(), type: term()}) :: [String.t()]
  def for_component(%{module_name: module_name} = component)
      when is_binary(module_name) and module_name != "" do
    module_path = module_path(module_name)
    source_path = source_path(module_path, Map.get(component, :type))

    [
      Paths.spec_dir() <> "/#{module_path}.spec.md",
      Paths.spec_dir() <> "/#{module_path}/design_review.md",
      "lib/#{source_path}.ex",
      "test/#{source_path}_test.exs"
    ]
  end

  def for_component(_component), do: []

  @doc """
  The underscored path for a module name — `CodeMySpec.Git.CLI` →
  `code_my_spec/git/cli`.

  Exact, unlike its inverse, which is the whole point of this module.
  """
  @spec module_path(String.t()) :: String.t()
  def module_path(module_name) do
    module_name
    |> Macro.underscore()
    |> String.replace(".", "/")
  end

  # Phoenix convention: LiveViews live in `live/`, controllers in `controllers/`.
  # Types arrive as strings from the database and as atoms from a changeset that
  # has not round-tripped, so both are accepted rather than assumed.
  defp source_path(module_path, type) when is_atom(type) and not is_nil(type),
    do: source_path(module_path, Atom.to_string(type))

  defp source_path(module_path, type)
       when type in ["liveview", "liveview_component", "live_context"],
       do: inject_dir_segment(module_path, "live")

  defp source_path(module_path, type) when type in ["controller", "json"],
    do: inject_dir_segment(module_path, "controllers")

  defp source_path(module_path, _type), do: module_path

  # "metric_flow_web/dashboard_live/show" → "metric_flow_web/live/dashboard_live/show"
  defp inject_dir_segment(path, dir) do
    case String.split(path, "/", parts: 2) do
      [first, rest] -> "#{first}/#{dir}/#{rest}"
      [single] -> "#{single}/#{dir}"
    end
  end
end
