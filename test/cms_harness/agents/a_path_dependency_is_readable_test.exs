defmodule CmsHarness.Agents.APathDependencyIsReadableTest do
  @moduledoc """
  An agent reads the source of a path dependency its checkout builds from,
  and its own app instance's state and log, and nothing else outside the
  checkout: a sibling repository that is not a dependency stays refused, and
  none of it is writable.
  """
  use ExUnit.Case, async: true

  alias Alloy.Tool.Core.Write
  alias CmsHarness.Agents.DepRoots
  alias CmsHarness.Agents.Tools.Read
  alias CmsHarness.AppInstance

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    checkout = Path.join(root, "app")
    dep = Path.join(root, "client_utils")
    sibling = Path.join(root, "unrelated")

    for {dir, file} <- [{checkout, "lib/app.ex"}, {dep, "lib/run_link.ex"}, {sibling, "lib/x.ex"}] do
      path = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "defmodule M do\nend\n")
    end

    context = %{
      working_directory: checkout,
      allowed_paths: [checkout],
      read_only_roots: fn %{working_directory: ^checkout} -> [dep] end
    }

    %{context: context, dep: dep, sibling: sibling}
  end

  test "a path dependency's source is readable", %{context: context, dep: dep} do
    assert {:ok, text} =
             Read.execute(%{"file_path" => Path.join(dep, "lib/run_link.ex")}, context)

    assert text =~ "defmodule M"
  end

  test "a sibling repository that is not a dependency is still refused", ctx do
    assert {:error, refused} =
             Read.execute(%{"file_path" => Path.join(ctx.sibling, "lib/x.ex")}, ctx.context)

    assert refused =~ "outside allowed directories"
  end

  test "a path dependency is not writable", %{context: context, dep: dep} do
    assert {:error, refused} =
             Write.execute(
               %{"file_path" => Path.join(dep, "lib/run_link.ex"), "content" => "x"},
               context
             )

    assert refused =~ "outside allowed directories"
  end

  test "a checkout's own app instance directories are named for its copy and its path" do
    root = AppInstance.instances_root()

    assert [by_path, by_copy] = AppInstance.own_dirs("/work/app", "copy-1")
    assert by_copy == Path.join(root, "copy-1")
    assert Path.dirname(by_path) == root
    assert AppInstance.own_dirs("/work/app", nil) == [by_path]
  end

  test "mix deps output names a path dependency's root and nothing else" do
    output = """
    * client_utils 0.3.0 (/Users/dev/github/client_utils) (mix)
      ok
    * cloak 1.1.4 (Hex package) (mix)
      locked at 1.1.4 (cloak) 92b20527
      ok
    * sexy_spex (https://github.com/Code-My-Spec/sexy_spex.git) (mix)
      locked at main (sexy_spex) 1b2c3d4
      ok
    * local_thing (/opt/src/local_thing) (mix)
      ok
    """

    assert DepRoots.parse(output) == ["/Users/dev/github/client_utils", "/opt/src/local_thing"]
  end
end
