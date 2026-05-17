defmodule Mix.Tasks.Cms.PackagePlugin do
  @moduledoc """
  Run the plugin file-shuffling step of the release packager locally,
  without burrito, the binary copy, or the GitHub release publish.

  Lays the plugin out the way `PackageExtension.execute/1` would, so you
  can inspect exactly what will ship and verify the dev→prod port rewrite
  before doing a full build.

  Lives in `lib_cli/` next to `PackageExtension`, so you need the CLI env
  on the path:

      MIX_ENV=dev_cli mix cms.package_plugin              # writes to release/codemyspec-extension
      MIX_ENV=dev_cli mix cms.package_plugin tmp/preview  # writes to a custom path

  Inspect the output:

      diff -r CodeMySpec release/codemyspec-extension/plugins/codemyspec
      grep -rn 4004 release/codemyspec-extension          # should be empty
      grep -rn 4003 release/codemyspec-extension          # should show rewrites
  """
  @shortdoc "Lay out the plugin release locally for inspection"
  use Boundary, classify_to: CodeMySpecCli
  use Mix.Task

  alias CodeMySpecCli.Release.PackageExtension

  @impl Mix.Task
  def run(args) do
    app_path = File.cwd!()
    source = Path.join(app_path, "CodeMySpec")

    unless File.dir?(source) do
      Mix.raise("No CodeMySpec/ directory at #{source} — run this from the repo root.")
    end

    extension_dir =
      case args do
        [dir | _] -> Path.expand(dir, app_path)
        _ -> Path.join([app_path, "release", "codemyspec-extension"])
      end

    %{extension_dir: out, plugin_dest: plugin} =
      PackageExtension.package_plugin_files(source, extension_dir)

    Mix.shell().info("")
    Mix.shell().info("Plugin laid out at: #{out}")
    Mix.shell().info("Plugin tree:        #{plugin}")
    Mix.shell().info("")
    Mix.shell().info("Inspect:")
    Mix.shell().info("  diff -r CodeMySpec #{Path.relative_to(plugin, app_path)}")
    Mix.shell().info("  grep -rn 4004 #{Path.relative_to(out, app_path)}    # should be empty")
  end
end
