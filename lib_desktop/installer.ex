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
    if match?({:win32, _}, :os.type()), do: put_onnxruntime_beside_erl(release.path)
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

  # Windows ships its own onnxruntime.dll (1.17) in System32, and the standard
  # DLL search tries System32 before the ortex NIF's own folder, so the NIF,
  # built against 1.19, loaded 1.17 and panicked ("requested API version [19]
  # is not available"). The executable's folder comes before System32: put the
  # bundled ONNX Runtime beside erl.exe.
  defp put_onnxruntime_beside_erl(release_path) do
    [bin] = Path.wildcard(Path.join(release_path, "erts-*/bin"))

    case Path.wildcard(Path.join(release_path, "lib/ortex-*/priv/native/onnxruntime*.dll")) do
      [] -> Mix.raise("No onnxruntime*.dll beside the ortex NIF; the build must put one there")
      dlls -> Enum.each(dlls, &File.cp!(&1, Path.join(bin, Path.basename(&1))))
    end
  end
end
