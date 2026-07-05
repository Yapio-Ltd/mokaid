defmodule Mokaid.Vault do
  @moduledoc """
  Symmetric encryption for credentials at rest (AES-256-GCM).

  The key comes from the `ENCRYPTION_KEY` env var (32 bytes, base64) and
  falls back to a key derived from `SECRET_KEY_BASE` so dev/test work out
  of the box. Payload layout: iv (12) <> tag (16) <> ciphertext.
  """

  @aad "mokaid-vault-v1"

  @spec encrypt(map() | binary()) :: binary()
  def encrypt(plaintext) when is_map(plaintext), do: plaintext |> Jason.encode!() |> encrypt()

  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @spec decrypt(binary() | nil) :: {:ok, binary()} | :error
  def decrypt(nil), do: :error

  def decrypt(<<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  end

  def decrypt(_), do: :error

  @spec decrypt_map(binary() | nil) :: {:ok, map()} | :error
  def decrypt_map(payload) do
    with {:ok, plaintext} <- decrypt(payload),
         {:ok, map} <- Jason.decode(plaintext) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  defp key do
    case System.get_env("ENCRYPTION_KEY") do
      nil ->
        secret =
          Application.get_env(:mokaid, MokaidWeb.Endpoint)[:secret_key_base] ||
            raise "Vault: neither ENCRYPTION_KEY nor secret_key_base is configured"

        :crypto.hash(:sha256, "mokaid-vault:" <> secret)

      encoded ->
        case Base.decode64(encoded) do
          {:ok, <<key::binary-size(32)>>} -> key
          _ -> raise "Vault: ENCRYPTION_KEY must be 32 bytes, base64-encoded"
        end
    end
  end
end
