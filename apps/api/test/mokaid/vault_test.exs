defmodule Mokaid.VaultTest do
  use ExUnit.Case, async: true

  alias Mokaid.Vault

  test "encrypts and decrypts binaries" do
    payload = Vault.encrypt("secret-token")
    refute payload == "secret-token"
    assert {:ok, "secret-token"} = Vault.decrypt(payload)
  end

  test "encrypts and decrypts maps" do
    payload = Vault.encrypt(%{"access_token" => "abc", "refresh_token" => "def"})

    assert {:ok, %{"access_token" => "abc", "refresh_token" => "def"}} =
             Vault.decrypt_map(payload)
  end

  test "rejects tampered payloads" do
    payload = Vault.encrypt("secret")
    <<first, rest::binary>> = payload
    assert :error = Vault.decrypt(<<Bitwise.bxor(first, 1), rest::binary>>)
    assert :error = Vault.decrypt(nil)
    assert :error = Vault.decrypt("too-short")
  end
end
