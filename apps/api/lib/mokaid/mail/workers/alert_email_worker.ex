defmodule Mokaid.Mail.Workers.AlertEmailWorker do
  @moduledoc """
  Sends the "important email arrived" alert through Resend when a mail rule
  with the `notify_email` action matches. Runs async on the notifications
  queue so mail ingestion never blocks on an external HTTP call.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Mokaid.Mail
  alias Mokaid.Mailer.Resend
  alias Mokaid.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "mail_account_id" => account_id,
          "message_id" => message_id,
          "rule_id" => rule_id
        }
      }) do
    with account when not is_nil(account) <- Mail.get_account_by_id(account_id),
         message when not is_nil(message) <- Mail.get_message_by_id(message_id) do
      account = Repo.preload(account, member: :user)
      rule = Mail.get_rule(account.workspace_id, rule_id)
      recipient = account.member && account.member.user && account.member.user.email

      if recipient do
        subject = "[mokaid] #{rule_title(rule)}: #{message.subject || "(no subject)"}"

        case Resend.deliver(recipient, subject, html_body(message, rule)) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  defp rule_title(nil), do: "Mail alert"
  defp rule_title(rule), do: rule.name

  defp html_body(message, rule) do
    from = escape(message.from_name || message.from_email || "Unknown sender")
    from_email = escape(message.from_email || "")
    subject = escape(message.subject || "(no subject)")
    summary = escape(message.ai_summary || message.snippet || "")
    rule_name = escape((rule && rule.name) || "Mail alert")

    excerpt =
      (message.body_text || "")
      |> String.slice(0, 1200)
      |> escape()
      |> String.replace("\n", "<br/>")

    """
    <div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:560px;margin:0 auto;padding:24px;color:#1a1a2e;">
      <p style="font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:#7c5cff;margin:0 0 4px;">mokaid · #{rule_name}</p>
      <h2 style="font-size:18px;margin:0 0 16px;">#{subject}</h2>
      <p style="font-size:13px;color:#555;margin:0 0 4px;"><strong>From:</strong> #{from} &lt;#{from_email}&gt;</p>
      #{if summary != "", do: ~s(<p style="font-size:13px;color:#555;margin:0 0 16px;"><strong>Summary:</strong> #{summary}</p>), else: ""}
      <div style="font-size:13px;line-height:1.6;background:#f6f5fb;border-radius:8px;padding:16px;color:#333;">#{excerpt}</div>
      <p style="font-size:11px;color:#999;margin-top:20px;">Sent by your mokaid mail agent. Manage rules in the Mail section.</p>
    </div>
    """
  end

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(_), do: ""
end
