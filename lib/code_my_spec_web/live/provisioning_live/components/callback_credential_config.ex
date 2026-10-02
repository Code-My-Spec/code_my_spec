defmodule CodeMySpecWeb.ProvisioningLive.Components.CallbackCredentialConfig do
  @moduledoc """
  The callback_credential step's own markup, factored out of `step_card`'s
  branches.

  Where the credential was placed — the observable form of "Sam never sees
  the credential he is using" (criterion 8022): written into the encrypted
  env, copied by nobody.
  """

  use CodeMySpecWeb, :html

  attr :step, :map, required: true

  def callback_credential_config(assigns) do
    ~H"""
    <div
      :for={cred <- Enum.filter(@step.resources, &(&1.kind == "callback_credential"))}
      data-test="callback-credential"
      data-placed-in="encrypted_env"
      data-manual-copy="false"
      data-environment={String.replace_prefix(cred.location, "encrypted_env/", "")}
      class="mt-2 text-xs opacity-70"
    >
      credential placed in {cred.location}
    </div>
    """
  end
end
