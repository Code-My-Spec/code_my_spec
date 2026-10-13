defmodule CodeMySpec.UserPreferences.DesktopUserTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.UserPreferences.DesktopUser

  describe "email/1" do
    test "is the OS user at localhost" do
      assert DesktopUser.email("johndavenport") == "johndavenport@localhost"
    end

    test "keeps only characters an email local part can carry, lowercased" do
      assert DesktopUser.email("John Davenport@corp") == "johndavenportcorp@localhost"
      assert DesktopUser.email("j.d_avenport-2") == "j.d_avenport-2@localhost"
    end

    test "falls back to user when there is nothing usable" do
      assert DesktopUser.email(nil) == "user@localhost"
      assert DesktopUser.email("@ ;") == "user@localhost"
    end
  end

  # Under :desktop it is the desktop user's scope; UserAuthDesktopTest covers
  # that, since flipping the env needs a non-async module.
  describe "scope/0" do
    test "is nil outside desktop, even when the desktop user exists" do
      user_fixture(%{email: DesktopUser.email()})
      assert DesktopUser.scope() == nil
    end
  end
end
