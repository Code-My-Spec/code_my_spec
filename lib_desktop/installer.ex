defmodule CodeMySpecDesktop.Installer do
  @moduledoc """
  The desktop release's installer step: a macOS `.dmg` or a Windows NSIS
  `.exe` from desktop_deployment, around the native webview host.

  `Desktop.Deployment.generate_installer/1` refuses any MIX_ENV but `prod`, and
  this release is `desktop` (prod + harness + overrides), so this is its body
  without that check. The host binary comes from `DESKTOP_HOST_BINARY` or the
  `desktop_package` config: desktop_webview is a git dependency and ships none.
  """

  alias Desktop.Deployment.Package

  @spec step(Mix.Release.t()) :: Mix.Release.t()
  def step(%Mix.Release{options: options} = release) do
    drop_debug_symbols(release.path)
    templates = Path.join(Mix.Project.deps_paths()[:desktop_deployment], "rel")
    options = options |> Keyword.put(:rel_templates_path, templates) |> Keyword.put(:quiet, true)

    package =
      %{release | options: options}
      |> Desktop.Deployment.package()
      |> Package.copy_extra_files()
      |> Package.create_installer()

    Mix.shell().info("Installer: #{package.priv[:installer_name] || "none created"}")
    package.release
  end

  # bcrypt_elixir's macOS build leaves `bcrypt_nif.so.dSYM/` in its priv; the
  # installer strips every `**/*.so`, and `strip` cannot process the DWARF file
  # inside that bundle. Debug symbols have no place in an installer anyway.
  defp drop_debug_symbols(release_path) do
    release_path |> Path.join("**/*.dSYM") |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)
  end
end
