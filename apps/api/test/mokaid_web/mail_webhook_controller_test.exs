defmodule MokaidWeb.MailWebhookControllerTest do
  use MokaidWeb.ConnCase, async: false
  use Oban.Testing, repo: Mokaid.Repo
  alias Mokaid.Mail.{Account, GmailPushAuth}

  @audience "https://mokaid.com/api/webhooks/gmail"
  @email "mokaid-gmail-push@mokaid.iam.gserviceaccount.com"

  setup do
    previous = Application.get_env(:mokaid, :gmail_pubsub)
    previous_http = Application.get_env(:mokaid, :gmail_push_http_options)
    Application.put_env(:mokaid, :gmail_pubsub, audience: @audience, service_account: @email)
    Application.put_env(:mokaid, :gmail_push_http_options, plug: {Req.Test, __MODULE__})
    :persistent_term.erase({GmailPushAuth, :keys})
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(key)
    {_, private} = JOSE.JWK.to_map(key)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{keys: [Map.put(public, "kid", "push-test")]})
    end)

    on_exit(fn ->
      :persistent_term.erase({GmailPushAuth, :keys})
      Application.put_env(:mokaid, :gmail_pubsub, previous)
      Application.put_env(:mokaid, :gmail_push_http_options, previous_http)
    end)

    signer = Joken.Signer.create("RS256", private, %{"kid" => "push-test"})
    now = System.system_time(:second)

    {:ok, token, _} =
      Joken.generate_and_sign(
        %{},
        %{
          "aud" => @audience,
          "email" => @email,
          "email_verified" => true,
          "iss" => "https://accounts.google.com",
          "iat" => now,
          "exp" => now + 3600
        },
        signer
      )

    %{authorization: "Bearer " <> token}
  end

  defp mailbox(email, status \\ "active") do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    Repo.insert!(%Account{
      workspace_id: workspace.id,
      member_id: member.id,
      email_address: email,
      provider: "gmail",
      status: status
    })
  end

  test "signed Gmail push fans out to every active matching workspace without duplicates", %{
    conn: conn,
    authorization: authorization
  } do
    one = mailbox("shared@example.com")
    two = mailbox("shared@example.com")
    mailbox("shared@example.com", "paused")
    mailbox("different@example.com")

    payload = %{
      message: %{
        data:
          Base.encode64(Jason.encode!(%{emailAddress: "SHARED@example.com", historyId: "123"}))
      }
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      for _ <- 1..2 do
        assert conn
               |> put_req_header("authorization", authorization)
               |> post("/api/webhooks/gmail", payload)
               |> json_response(200) == %{"status" => "ok"}
      end

      ids =
        all_enqueued(worker: Mokaid.Mail.Workers.SyncWorker)
        |> Enum.map(& &1.args["mail_account_id"])

      assert Enum.sort(ids) == Enum.sort([one.id, two.id])
    end)
  end

  test "invalid signature cannot queue a mailbox sync", %{conn: conn} do
    mailbox("shared@example.com")

    payload = %{
      message: %{data: Base.encode64(Jason.encode!(%{emailAddress: "shared@example.com"}))}
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert conn
             |> put_req_header("authorization", "Bearer forged")
             |> post("/api/webhooks/gmail", payload)
             |> json_response(401)

      assert all_enqueued(worker: Mokaid.Mail.Workers.SyncWorker) == []
    end)
  end
end
