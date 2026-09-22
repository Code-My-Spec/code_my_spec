defmodule CodeMySpec.Workspaces.PreviewAddressTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Workspaces.PreviewAddress

  describe "the address itself" do
    test "is derived from the project, so it survives every container" do
      id = Ecto.UUID.generate()

      assert PreviewAddress.host(id) == PreviewAddress.host(id)
      assert PreviewAddress.host(id) =~ id
    end

    test "is one label deep, which is what a free wildcard certificate covers" do
      host = PreviewAddress.host(Ecto.UUID.generate())

      assert length(String.split(host, ".")) == 3,
             "a second level down needs Advanced Certificate Manager; " <>
               "preview-{id}.codemyspec.com does not"
    end

    test "two projects never share an address" do
      refute PreviewAddress.host(Ecto.UUID.generate()) ==
               PreviewAddress.host(Ecto.UUID.generate())
    end
  end

  describe "csp_extra_frame_origins/0" do
    test "defaults to the two OAuth providers a generated app is likely to offer" do
      assert PreviewAddress.csp_extra_frame_origins() == [
               "https://accounts.google.com",
               "https://github.com"
             ]
    end

    test "an added provider does not need a code change" do
      previous = Application.get_env(:code_my_spec, PreviewAddress, [])

      Application.put_env(
        :code_my_spec,
        PreviewAddress,
        Keyword.put(previous, :extra_frame_origins, ["gitlab.com"])
      )

      on_exit(fn -> Application.put_env(:code_my_spec, PreviewAddress, previous) end)

      assert PreviewAddress.csp_extra_frame_origins() == ["https://gitlab.com"]
    end
  end

  describe "extra_frame_origins/1 and csp_extra_frame_origins/1, per project" do
    test "no project falls back to the config/built-in default, same as arity 0" do
      assert PreviewAddress.extra_frame_origins(nil) == ["accounts.google.com", "github.com"]

      assert PreviewAddress.csp_extra_frame_origins(nil) ==
               PreviewAddress.csp_extra_frame_origins()
    end

    test "a project that never customized it also falls back to the default" do
      project = %Project{preview_extra_frame_origins: nil}

      assert PreviewAddress.extra_frame_origins(project) == ["accounts.google.com", "github.com"]
    end

    test "a project's own list is used exactly, in place of the default" do
      project = %Project{preview_extra_frame_origins: ["gitlab.com"]}

      assert PreviewAddress.extra_frame_origins(project) == ["gitlab.com"]
      assert PreviewAddress.csp_extra_frame_origins(project) == ["https://gitlab.com"]
    end

    test "a project that explicitly cleared it allows nothing extra" do
      project = %Project{preview_extra_frame_origins: []}

      assert PreviewAddress.extra_frame_origins(project) == []
      assert PreviewAddress.csp_extra_frame_origins(project) == []
    end
  end
end
