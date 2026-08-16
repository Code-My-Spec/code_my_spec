defmodule CodeMySpec.MailNotConfiguredTest do
  @moduledoc """
  What the mail flow does with no Resend key at all.

  One test, in a file of its own, for the same reason as
  `Provisioning.HetznerCredentialsTest`: it is the only one in this area that
  asserts on the *absence* of application environment rather than on what the
  provider replied. `Req.Test` scopes a response to the calling process;
  taking the key away is node-wide however it is done.

  Left in `mail_domain_test` it would have kept that file — and
  `mail_attachments_test` with it, since both drive the same client — sync.
  """

  # Sync: `Application.put_env/3` below is visible to the whole node, and
  # `config/test.exs` sets this key for the suite.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Mail
  alias CodeMySpec.Mail.ResendClient

  setup do
    previous = Application.get_env(:code_my_spec, ResendClient, [])
    Application.put_env(:code_my_spec, ResendClient, Keyword.put(previous, :api_key, ""))
    on_exit(fn -> Application.put_env(:code_my_spec, ResendClient, previous) end)
    :ok
  end

  test "surfaces a clear error when the provider key is missing" do
    scope = full_scope_fixture()

    assert {:error, :resend_not_configured} =
             Mail.setup_domain(scope, scope.active_project, "inbound.sam-ships.com")
  end
end
