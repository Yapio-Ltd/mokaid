defmodule Mokaid.Mail.GmailPushAuthTest do
  use ExUnit.Case, async: false
  alias Mokaid.Mail.GmailPushAuth

  @audience "https://mokaid.com/api/webhooks/gmail"
  @email "mokaid-gmail-push@mokaid.iam.gserviceaccount.com"

  setup do
    config = Application.get_env(:mokaid, :gmail_pubsub)
    http = Application.get_env(:mokaid, :gmail_push_http_options)
    Application.put_env(:mokaid, :gmail_pubsub, audience: @audience, service_account: @email)
    Application.put_env(:mokaid, :gmail_push_http_options, plug: {Req.Test, __MODULE__})
    :persistent_term.erase({GmailPushAuth, :keys})

    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)
    public = Map.put(public, "kid", "push-test")
    {_, private} = JOSE.JWK.to_map(key)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth2/v3/certs"
      Req.Test.json(conn, %{keys: [public]})
    end)

    on_exit(fn ->
      :persistent_term.erase({GmailPushAuth, :keys})
      restore(:gmail_pubsub, config)
      restore(:gmail_push_http_options, http)
    end)

    %{signer: Joken.Signer.create("RS256", private, %{"kid" => "push-test"})}
  end

  test "accepts only the intended signed, verified and unexpired push identity", %{signer: signer} do
    assert :ok == GmailPushAuth.verify(token(signer))

    for override <- [
          %{"aud" => "https://other.example"},
          %{"email" => "other@mokaid.iam.gserviceaccount.com"},
          %{"email_verified" => false},
          %{"iss" => "https://attacker.example"},
          %{"exp" => System.system_time(:second) - 1},
          %{"iat" => System.system_time(:second) + 300},
          %{"exp" => "tomorrow"}
        ] do
      assert {:error, :unauthorized} == GmailPushAuth.verify(token(signer, override))
    end
  end

  test "rejects forged signatures, malformed tokens and missing configuration", %{signer: signer} do
    other_key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, private} = JOSE.JWK.to_map(other_key)
    attacker = Joken.Signer.create("RS256", private, %{"kid" => "push-test"})
    assert {:error, :unauthorized} == GmailPushAuth.verify(token(attacker))

    for value <- [nil, "", "Bearer not-a-jwt", "Bearer " <> String.duplicate("x", 8193)] do
      assert {:error, :unauthorized} == GmailPushAuth.verify(value)
    end

    Application.put_env(:mokaid, :gmail_pubsub, audience: @audience)
    assert {:error, :unauthorized} == GmailPushAuth.verify(token(signer))
  end

  test "webhook rejects unauthenticated requests before account lookup" do
    conn = Phoenix.ConnTest.build_conn(:post, "/api/webhooks/gmail", %{})
    conn = MokaidWeb.MailWebhookController.gmail(conn, %{})
    assert conn.status == 401
  end

  defp token(signer, override \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "aud" => @audience,
          "email" => @email,
          "email_verified" => true,
          "iss" => "https://accounts.google.com",
          "iat" => now,
          "exp" => now + 3600
        },
        override
      )

    {:ok, jwt, _} = Joken.generate_and_sign(%{}, claims, signer)
    "Bearer " <> jwt
  end

  defp restore(key, nil), do: Application.delete_env(:mokaid, key)
  defp restore(key, value), do: Application.put_env(:mokaid, key, value)
end
