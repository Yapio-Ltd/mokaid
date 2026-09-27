defmodule Mokaid.Mail.Composer do
  @moduledoc "Validated, workspace-authorized email sending with a durable no-retry claim."
  import Ecto.Query
  alias Mokaid.{Mail, Permissions, Repo, Vault}
  alias Mokaid.Mail.{Account, Message, Outbox}
  alias Mokaid.Members.Member

  @max_attachment_bytes 5 * 1024 * 1024
  @email ~r/^[A-Za-z0-9.!#$%&'*+\/=\?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$/
  @safe_errors ~w(provider_rejected authentication_required permission_required smtp_not_configured smtp_connection_failed smtp_tls_failed recipients_rejected delivery_unknown worker_unavailable invalid_message)

  def send(workspace_id, member, params, opts \\ []) do
    with {:ok, member} <- authorized(workspace_id, member),
         {:ok, normalized} <- validate(params) do
      # A replay must report the saved outcome even after the mailbox or reply
      # was deleted. A fresh preflight failure must not hide an accepted send.
      case Repo.get_by(Outbox,
             workspace_id: workspace_id,
             member_id: member.id,
             request_id: normalized["request_id"]
           ) do
        %Outbox{} = entry ->
          if entry.request_hash == request_hash(normalized),
            do: {:ok, public(entry)},
            else: {:error, :idempotency_conflict}

        nil ->
          with {:ok, account} <- active_account(workspace_id, normalized["account_id"]),
               {:ok, envelope} <- reply_envelope(workspace_id, account, normalized),
               {:ok, claim, fresh?} <- claim(workspace_id, member, account, normalized) do
            if fresh?,
              do: deliver(claim, account, member, envelope, opts),
              else: {:ok, public(claim)}
          end
      end
    end
  end

  def status(workspace_id, member, id) do
    with {:ok, member} <- authorized(workspace_id, member),
         {:ok, id} <- uuid(id),
         %Outbox{} = entry <-
           Repo.get_by(Outbox, id: id, workspace_id: workspace_id, member_id: member.id) do
      {:ok, public(entry)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def outgoing_attachment(workspace_id, message_id, attachment_id) do
    with %Outbox{status: "sent"} = entry <-
           Repo.get_by(Outbox, workspace_id: workspace_id, message_id: message_id),
         {:ok, %{"attachments" => attachments}} <- Vault.decrypt_map(entry.encrypted_attachments),
         true <- is_binary(attachment_id),
         {index, ""} when index >= 0 <- Integer.parse(attachment_id),
         %{} = attachment <- Enum.at(attachments, index),
         {:ok, bytes} <- Base.decode64(attachment["content_base64"]) do
      {:ok,
       %{
         filename: attachment["filename"],
         mime_type: attachment["content_type"],
         content_base64: attachment["content_base64"],
         size: byte_size(bytes)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def validate(params) when is_map(params) do
    with {:ok, request_id} <- uuid(params["request_id"]),
         {:ok, account_id} <- uuid(params["account_id"]),
         {:ok, to} <- addresses(params["to"] || []),
         {:ok, cc} <- addresses(params["cc"] || []),
         {:ok, bcc} <- addresses(params["bcc"] || []),
         true <- (length(to) + length(cc) + length(bcc)) in 1..100,
         true <- safe_header?(params["subject"] || "", 998),
         body when is_binary(body) <- params["body_text"],
         true <-
           String.valid?(body) and byte_size(body) <= 200_000 and
             not String.contains?(body, <<0>>),
         {:ok, reply_id} <- optional_uuid(params["in_reply_to"]),
         {:ok, attachments} <- attachments(params["attachments"] || []) do
      {:ok,
       %{
         "request_id" => request_id,
         "account_id" => account_id,
         "to" => to,
         "cc" => cc,
         "bcc" => bcc,
         "subject" => params["subject"] || "",
         "body_text" => body,
         "in_reply_to" => reply_id,
         "attachments" => attachments
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def validate(_), do: {:error, :invalid_message}

  defp authorized(workspace_id, %{id: member_id}) do
    case Repo.get_by(Member, id: member_id, workspace_id: workspace_id, status: "active")
         |> Repo.preload([:role, :user]) do
      %Member{user: %{status: "active"}} = member ->
        with :ok <- Permissions.authorize(member, "mail.send"), do: {:ok, member}

      _ ->
        {:error, :forbidden}
    end
  end

  defp authorized(_, _), do: {:error, :forbidden}

  defp active_account(workspace_id, id) do
    case Repo.get_by(Account, workspace_id: workspace_id, id: id, status: "active") do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  defp reply_envelope(workspace_id, account, params) do
    envelope = params |> Map.drop(["request_id", "account_id", "in_reply_to"])

    case params["in_reply_to"] do
      nil ->
        {:ok, envelope}

      id ->
        case Repo.get_by(Message, id: id, workspace_id: workspace_id, mail_account_id: account.id) do
          nil ->
            {:error, :invalid_reply}

          message ->
            with {:ok, message} <- hydrate_reply(message) do
              header = Map.get(message, :rfc_message_id)
              references = Map.get(message, :references, []) || []

              {:ok,
               envelope
               |> Map.put("in_reply_to", header)
               |> Map.put("references", references)
               |> Map.put("thread_id", message.thread_id)}
            end
        end
    end
  end

  defp hydrate_reply(%{rfc_message_id: id} = message) when is_binary(id) and id != "",
    do: {:ok, message}

  defp hydrate_reply(message), do: Mokaid.Mail.MessageActions.hydrate(message)

  defp claim(workspace_id, member, account, params) do
    hash = request_hash(params)
    now = DateTime.utc_now()

    entry = %{
      id: Ecto.UUID.generate(),
      workspace_id: workspace_id,
      member_id: member.id,
      account_id: account.id,
      request_id: params["request_id"],
      request_hash: hash,
      status: "sending",
      encrypted_attachments: Vault.encrypt(%{"attachments" => params["attachments"]}),
      inserted_at: now,
      updated_at: now
    }

    {count, _} =
      Repo.insert_all(Outbox, [entry],
        on_conflict: :nothing,
        conflict_target: [:workspace_id, :member_id, :request_id]
      )

    saved =
      Repo.get_by!(Outbox,
        workspace_id: workspace_id,
        member_id: member.id,
        request_id: params["request_id"]
      )

    if saved.request_hash == hash,
      do: {:ok, saved, count == 1},
      else: {:error, :idempotency_conflict}
  end

  defp deliver(claim, account, member, envelope, opts) do
    credentials_fn = Keyword.get(opts, :credentials, &Mail.worker_account_payload/1)
    dispatch_fn = Keyword.get(opts, :dispatch, &dispatch/1)
    envelope = Map.put(envelope, "message_id", "<#{claim.id}@mokaid.com>")

    prepared =
      with {:ok, payload} <- credentials_fn.(account),
           {:ok, _} <- authorized(account.workspace_id, member),
           {:ok, current} <- active_account(account.workspace_id, account.id),
           true <- same_account?(current, account),
           do: {:ok, payload}

    result =
      case prepared do
        {:ok, payload} -> dispatch_fn.(%{account: payload, message: envelope})
        _ -> {:error, :preflight_failed}
      end

    case result do
      {:ok, %{"status" => "sent"} = response} ->
        finish_sent(claim, account, envelope, response)

      {:ok, %{"status" => "failed"} = response} ->
        finish(claim, "failed", safe_error(response["error"]))

      {:error, :preflight_failed} ->
        finish(claim, "failed", "authentication_required")

      {:error, :mail_worker_unavailable} ->
        finish(claim, "failed", "worker_unavailable")

      _ ->
        finish(claim, "unknown", "delivery_unknown")
    end
  rescue
    _ -> finish(claim, "unknown", "delivery_unknown")
  end

  defp dispatch(payload), do: Mokaid.Mail.WorkerRPC.post("/mail/send", payload)

  defp same_account?(current, before) do
    Map.take(current, [:connection_id, :email_address, :settings, :encrypted_credentials]) ==
      Map.take(before, [:connection_id, :email_address, :settings, :encrypted_credentials])
  end

  defp finish_sent(claim, account, envelope, response) do
    provider_id = response["provider_message_id"] || "outbox:#{claim.id}"

    attrs = %{
      "workspace_id" => account.workspace_id,
      "mail_account_id" => account.id,
      "provider_message_id" => provider_id,
      "thread_id" => response["thread_id"] || envelope["thread_id"],
      "from_email" => account.email_address,
      "from_name" => account.display_name,
      "to_emails" => envelope["to"],
      "cc_emails" => envelope["cc"],
      "subject" => envelope["subject"],
      "body_text" => envelope["body_text"],
      "snippet" => String.slice(envelope["body_text"], 0, 250),
      "folder" => "sent",
      "labels" => ["SENT"],
      "is_read" => true,
      "received_at" => DateTime.utc_now(),
      "has_attachments" => envelope["attachments"] != [],
      "rfc_message_id" => envelope["message_id"],
      "provider_metadata" => %{"outbox_id" => claim.id},
      "attachments" =>
        Enum.with_index(envelope["attachments"], fn item, index ->
          %{
            "id" => to_string(index),
            "filename" => item["filename"],
            "mime_type" => item["content_type"],
            "size" => byte_size(Base.decode64!(item["content_base64"]))
          }
        end)
    }

    # Provider acceptance is durable even if the account was removed or local indexing fails.
    claim =
      claim
      |> Ecto.Changeset.change(status: "sent", provider_message_id: provider_id)
      |> Repo.update!()

    case %Message{}
         |> Message.changeset(attrs)
         |> Repo.insert(
           on_conflict: :nothing,
           conflict_target: [:mail_account_id, :provider_message_id]
         ) do
      {:ok, _} ->
        message =
          Repo.get_by(Message, mail_account_id: account.id, provider_message_id: provider_id)

        updated =
          claim |> Ecto.Changeset.change(message_id: message && message.id) |> Repo.update!()

        {:ok, public(updated)}

      _ ->
        {:ok, public(claim)}
    end
  end

  defp finish(claim, status, error) do
    # Never downgrade an acknowledged send if indexing raised after persistence.
    from(o in Outbox, where: o.id == ^claim.id and o.status == "sending")
    |> Repo.update_all(set: [status: status, error: error, updated_at: DateTime.utc_now()])

    {:ok, claim.id |> then(&Repo.get!(Outbox, &1)) |> public()}
  end

  defp public(entry) do
    stale? =
      entry.status == "sending" and DateTime.diff(DateTime.utc_now(), entry.inserted_at) > 120

    %{
      id: entry.id,
      request_id: entry.request_id,
      status: if(stale?, do: "unknown", else: entry.status),
      message_id: entry.message_id,
      error: if(stale?, do: "delivery_unknown", else: entry.error)
    }
  end

  defp safe_error(value), do: if(value in @safe_errors, do: value, else: "provider_rejected")
  defp request_hash(params), do: :crypto.hash(:sha256, :erlang.term_to_binary(params))

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_message}
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: uuid(value)

  defp safe_header?(value, limit),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= limit and
        not Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp addresses(values) when is_list(values) and length(values) <= 100 do
    if Enum.all?(values, &(safe_header?(&1, 254) and Regex.match?(@email, &1))),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_message}
  end

  defp addresses(_), do: {:error, :invalid_message}

  defp attachments(values) when is_list(values) and length(values) <= 10 do
    Enum.reduce_while(values, {:ok, [], 0}, fn value, {:ok, acc, size} ->
      with %{"filename" => filename, "content_type" => type, "content_base64" => encoded} <- value,
           true <-
             safe_header?(filename, 255) and filename != "" and
               not String.contains?(filename, ["/", "\\"]),
           true <- is_binary(type) and Regex.match?(~r/^[a-zA-Z0-9.+-]+\/[a-zA-Z0-9.+-]+$/, type),
           true <- is_binary(encoded) and byte_size(encoded) <= 7_000_000,
           {:ok, bytes} <- Base.decode64(encoded),
           true <- size + byte_size(bytes) <= @max_attachment_bytes do
        {:cont,
         {:ok,
          [%{"filename" => filename, "content_type" => type, "content_base64" => encoded} | acc],
          size + byte_size(bytes)}}
      else
        _ -> {:halt, {:error, :invalid_message}}
      end
    end)
    |> case do
      {:ok, entries, _} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp attachments(_), do: {:error, :invalid_message}
end
