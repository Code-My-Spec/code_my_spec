defmodule CodeMySpec.Workspaces.PreviewAddressTest do
  use CodeMySpecTest.DataCase, async: true

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
end
