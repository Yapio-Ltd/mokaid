defmodule Mokaid.MailConnectionTest do
  use ExUnit.Case, async: true
  alias Mokaid.Mail.{ConnectionSettings, ImapProbe, ProbeSocket, SmtpProbe}

  defmodule Transport do
    def connect(_, _, security, _) do
      record({:connect, security})
      {:ok, :socket}
    end

    def starttls(_, _, _) do
      record(:starttls)
      Process.get(:upgrade_result, {:ok, :secured})
    end

    def send_line(socket, line) do
      record({socket, line})
      :ok
    end

    def recv_line(_) do
      case Process.get(:responses, []) do
        [line | rest] ->
          Process.put(:responses, rest)
          {:ok, line}

        [] ->
          {:error, :closed}
      end
    end

    def close(_), do: :ok
    defp record(value), do: Process.put(:commands, Process.get(:commands, []) ++ [value])
  end

  @attrs %{
    "email_address" => " me@example.com ",
    "username" => "",
    "password" => "app password",
    "imap_host" => " imap.example.com "
  }

  test "normalizes empty usernames and explicit TLS defaults without putting passwords in settings" do
    assert {:ok, attrs} = ConnectionSettings.normalize(@attrs)
    assert attrs["username"] == "me@example.com"
    assert attrs["imap_port"] == 993
    assert attrs["imap_security"] == "tls"
    assert attrs["smtp_security"] == "starttls"
    refute Map.has_key?(ConnectionSettings.settings(attrs), "password")
    assert ConnectionSettings.credentials(attrs)["password"] == "app password"
  end

  test "legacy false SSL means required STARTTLS, never plaintext" do
    assert {:ok, attrs} = ConnectionSettings.normalize(Map.put(@attrs, "imap_ssl", false))
    assert attrs["imap_security"] == "starttls"
    assert attrs["imap_port"] == 143
  end

  test "rejects invalid ports, host URLs, CRLF credentials and insecure modes before probing" do
    for invalid <- [
          %{"imap_port" => "993garbage"},
          %{"imap_port" => 0},
          %{"imap_port" => 65536},
          %{"imap_host" => "https://imap.example.com"},
          %{"password" => "pw\r\nA1 LOGOUT"},
          %{"imap_security" => "none"},
          %{"email_address" => 123},
          %{"email_address" => %{}},
          %{"password" => []},
          %{"imap_port" => true},
          %{"email_address" => nil},
          %{"imap_host" => nil}
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               ConnectionSettings.normalize(Map.merge(@attrs, invalid))
    end
  end

  test "rejects private, loopback, metadata and reserved probe destinations" do
    for ip <- [
          {127, 0, 0, 1},
          {169, 254, 169, 254},
          {10, 0, 0, 1},
          {172, 16, 0, 1},
          {192, 168, 1, 1},
          {100, 64, 0, 1},
          {0, 0, 0, 0},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1}
        ] do
      refute ProbeSocket.public_address?(ip)
    end

    assert ProbeSocket.public_address?({8, 8, 8, 8})
    assert ProbeSocket.public_address?({0x2607, 0xF8B0, 0, 0, 0, 0, 0, 1})
  end

  test "IMAP requires greeting, STARTTLS, tagged login and readable INBOX" do
    Process.put(:responses, [
      "* OK ready\r\n",
      "S1 OK begin TLS\r\n",
      "* CAPABILITY IMAP4rev1\r\n",
      "A1 ok logged in\r\n",
      "* 2 EXISTS\r\n",
      "A2 OK read only\r\n"
    ])

    assert :ok =
             ImapProbe.check("mail.example.com", 143, "me", "p\\\"w",
               security: "starttls",
               transport: Transport
             )

    assert [
             {:connect, "starttls"},
             {:socket, "S1 STARTTLS"},
             :starttls,
             {:secured, login},
             {:secured, "A2 EXAMINE INBOX"},
             {:secured, "A3 LOGOUT"}
           ] = Process.get(:commands)

    assert login == "A1 LOGIN \"me\" \"p\\\\\\\"w\""
  end

  test "IMAP never sends a password after rejected TLS upgrade" do
    Process.put(:responses, ["* OK ready\r\n", "S1 NO unavailable\r\n"])

    assert {:error, :starttls_unavailable} =
             ImapProbe.check("mail.example.com", 143, "me", "secret",
               security: "starttls",
               transport: Transport
             )

    refute inspect(Process.get(:commands)) =~ "secret"
  end

  test "IMAP does not accept a tagged success embedded in an untagged server response" do
    Process.put(:responses, ["* OK ready\r\n", "* OK message A1 OK\r\n", "A1 NO bad password\r\n"])

    assert {:error, :auth_failed} =
             ImapProbe.check("mail.example.com", 993, "me", "secret", transport: Transport)
  end

  test "SMTP authenticates only after STARTTLS and never sends mail" do
    Process.put(:responses, [
      "220 ready\r\n",
      "250-mail.example.com\r\n",
      "250 STARTTLS\r\n",
      "220 start TLS\r\n",
      "250-mail.example.com\r\n",
      "250 AUTH PLAIN LOGIN\r\n",
      "235 authenticated\r\n"
    ])

    assert :ok = SmtpProbe.check("smtp.example.com", 587, "me", "pw", transport: Transport)
    commands = Process.get(:commands)

    assert [
             {:connect, "starttls"},
             {:socket, "EHLO mokaid.app"},
             {:socket, "STARTTLS"},
             :starttls,
             {:secured, "EHLO mokaid.app"},
             {:secured, auth},
             {:secured, "QUIT"}
           ] = commands

    assert auth == "AUTH PLAIN " <> Base.encode64(<<0>> <> "me" <> <<0>> <> "pw")
    refute inspect(commands) =~ "MAIL FROM"
  end

  test "SMTP handles AUTH LOGIN and reports rejected authentication" do
    Process.put(:responses, [
      "220 ready\r\n",
      "250 AUTH LOGIN\r\n",
      "334 username\r\n",
      "334 password\r\n",
      "535 rejected\r\n"
    ])

    assert {:error, :auth_failed} =
             SmtpProbe.check("smtp.example.com", 465, "me", "pw",
               security: "tls",
               transport: Transport
             )
  end

  test "SMTP stops before credentials when certificate validation fails" do
    Process.put(:responses, ["220 ready\r\n", "250 STARTTLS\r\n", "220 start TLS\r\n"])
    Process.put(:upgrade_result, {:error, :tls_failed})

    assert {:error, :tls_failed} =
             SmtpProbe.check("smtp.example.com", 587, "me", "pw", transport: Transport)

    refute inspect(Process.get(:commands)) =~ "AUTH"
  end
end
