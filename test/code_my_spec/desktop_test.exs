defmodule CodeMySpec.DesktopTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Desktop

  describe "email/1" do
    test "is the OS user at localhost" do
      assert Desktop.email("johndavenport") == "johndavenport@localhost"
    end

    test "keeps only characters an email local part can carry, lowercased" do
      assert Desktop.email("John Davenport@corp") == "johndavenportcorp@localhost"
      assert Desktop.email("j.d_avenport-2") == "j.d_avenport-2@localhost"
    end

    test "falls back to user when there is nothing usable" do
      assert Desktop.email(nil) == "user@localhost"
      assert Desktop.email("@ ;") == "user@localhost"
    end
  end

  describe "scope/0" do
    test "is the desktop user's scope" do
      user = user_fixture(%{email: Desktop.email()})
      assert Desktop.scope().user.id == user.id
    end

    test "is nil before the desktop user exists" do
      assert Desktop.scope() == nil
    end
  end
end
