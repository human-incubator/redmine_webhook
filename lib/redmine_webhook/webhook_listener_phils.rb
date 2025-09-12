require 'date'

module RedmineWebhook
  class WebhookListener < Redmine::Hook::Listener
    def status_record
      @status_map ||= IssueStatus.all.index_by { |s| s.id.to_s }.transform_values(&:name)
    end

    def skip_webhooks(context)
      return true unless context[:request]
      return true if context[:request].headers['X-Skip-Webhooks']
      false
    end

    def controller_issues_new_after_save(context = {})
      return if skip_webhooks(context)

      issue = context[:issue]
      controller = context[:controller]
      project = issue.project

      webhooks = Webhook.where(project_id: project.project.id)
      webhooks = Webhook.where(project_id: 0) if webhooks.blank?
      return if webhooks.blank?

      begin
        payload = issue_to_json(issue, controller)
        post(webhooks, payload)
      rescue => e
        Rails.logger.error "[Webhook] Error in webhook creation: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    def controller_issues_edit_after_save(context = {})
      return if skip_webhooks(context)

      journal = context[:journal]
      controller = context[:controller]
      issue = context[:issue]
      project = issue.project

      webhooks = Webhook.where(project_id: project.project.id)
      webhooks = Webhook.where(project_id: 0) if webhooks.blank?
      return if webhooks.blank?

      post(webhooks, journal_to_json(issue, journal, controller))
    end

    def controller_issues_bulk_edit_after_save(context = {})
      return if skip_webhooks(context)

      journal = context[:journal]
      controller = context[:controller]
      issue = context[:issue]
      project = issue.project

      webhooks = Webhook.where(project_id: project.project.id)
      webhooks = Webhook.where(project_id: 0) if webhooks.blank?
      return if webhooks.blank?

      post(webhooks, journal_to_json(issue, journal, controller))
    end

    def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context = {})
      issue = context[:issue]
      journal = issue.current_journal

      webhooks = Webhook.where(project_id: issue.project.project.id)
      webhooks = Webhook.where(project_id: 0) if webhooks.blank?
      return if webhooks.blank?

      post(webhooks, journal_to_json(issue, journal, nil))
    end

    private

    def issue_to_json(issue, controller)
      {
        payload: {
          action: 'opened',
          issue: RedmineWebhook::IssueWrapper.new(issue).to_hash,
          url: controller.issue_url(issue)
        }
      }.to_json
    end

    def journal_to_json(issue, journal, controller)
      {
        payload: {
          action: 'updated',
          issue: RedmineWebhook::IssueWrapper.new(issue).to_hash,
          journal: RedmineWebhook::JournalWrapper.new(journal).to_hash,
          url: controller.nil? ? 'not yet implemented' : controller.issue_url(issue)
        }
      }.to_json
    end

    def post(webhooks, request_body)
      webhooks.each do |webhook|
        begin
          payload = JSON.parse(request_body)
          issue   = payload["payload"]["issue"]
          journal = payload["payload"]["journal"]
          Rails.logger.error "Payload is #{payload}"

          author =
            if journal&.dig("author", "firstname")
              "#{journal['author']['firstname']} #{journal['author']['lastname']}"
            else
              "#{issue['author']['firstname']} #{issue['author']['lastname']}"
            end

          subject_line = "[#{issue['project']['name']} - #{issue['tracker']['name']} ##{issue['id']}] (#{issue['status']['name']}) #{issue['subject']}"

          lines = []
          lines << "📌 Redmine #{journal ? 'Update' : 'New'}"
          lines << "Subject: #{subject_line}\n"
          lines << "Issue ##{issue['id']} was #{journal ? 'updated' : 'created'} by #{author}.\n" 

          # Notes
          lines << "#{journal['notes']}\n" if journal && !journal['notes'].empty?

          # Issue URL
          lines << "URL: #{payload['payload']['url']}"

          chat_message = { text: lines.join("\n") }

          Faraday.post(webhook.url) do |req|
            req.headers['Content-Type'] = 'application/json'
            req.body = chat_message.to_json
          end
        rescue => e
          Rails.logger.error "Failed to post webhook to #{webhook.url}: #{e.message}"
        end
      end
    end
  end
end
