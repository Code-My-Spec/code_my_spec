defmodule CodeMySpecDesktop.IdentityTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpecDesktop.Identity

  describe "email/1" do
    test "is the OS user at localhost" do
      assert Identity.email("johndavenport") == "johndavenport@localhost"
    end

    test "keeps only characters an email local part can carry, lowercased" do
      assert Identity.email("John Davenport@corp") == "johndavenportcorp@localhost"
      assert Identity.email("j.d_avenport-2") == "j.d_avenport-2@localhost"
    end

    test "falls back to user when there is nothing usable" do
      assert Identity.email(nil) == "user@localhost"
      assert Identity.email("@ ;") == "user@localhost"
    end
  end

  # Under :desktop it is the desktop user's scope; UserAuthDesktopTest covers
  # that, since flipping the env needs a non-async module.
  describe "scope/0" do
    test "is nil outside desktop, even when the desktop user exists" do
      user_fixture(%{email: Identity.email()})
      assert Identity.scope() == nil
    end
  end
end
