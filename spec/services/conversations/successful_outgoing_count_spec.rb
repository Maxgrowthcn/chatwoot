require 'rails_helper'

RSpec.describe Conversations::SuccessfulOutgoingCount do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:pending_conversation) { create(:conversation, account: account, status: :pending) }
  let(:resolved_conversation) { create(:conversation, account: account, status: :resolved) }
  let(:empty_conversation) { create(:conversation, account: account) }

  describe '.preload' do
    it 'counts sent, delivered, and read public outgoing replies, including bots, for any conversation status' do
      bot = create(:agent_bot, account: account)
      create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :sent)
      create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :delivered)
      create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :read, sender: bot)
      create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :sent,
                       additional_attributes: { 'template_params' => { 'name' => 'hello' } })
      create(:message, conversation: resolved_conversation, account: account, message_type: :outgoing, status: :read)

      described_class.preload([pending_conversation, resolved_conversation, empty_conversation])

      expect(pending_conversation.successful_outgoing_count).to eq(4)
      expect(resolved_conversation.successful_outgoing_count).to eq(1)
      expect(empty_conversation.successful_outgoing_count).to eq(0)
    end

    it 'excludes failed, incoming, private, activity, and template messages' do
      create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :failed)
      create(:message, conversation: pending_conversation, account: account, message_type: :incoming, status: :sent)
      create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, private: true, status: :sent)
      create(:message, conversation: pending_conversation, account: account, message_type: :activity, status: :sent, content: 'Assigned')
      create(:message, conversation: pending_conversation, account: account, message_type: :template, status: :sent, content: 'Greeting')
      unset_status = create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :sent)
      unset_status.update_columns(status: nil) # rubocop:disable Rails/SkipsModelValidations

      described_class.preload([pending_conversation])

      expect(pending_conversation.successful_outgoing_count).to eq(0)
    end

    it 'does not count a message whose account does not match the conversation' do
      message = create(:message, conversation: pending_conversation, account: account, message_type: :outgoing, status: :sent)
      message.update_columns(account_id: other_account.id) # rubocop:disable Rails/SkipsModelValidations
      other_conversation = create(:conversation, account: other_account)
      create(:message, conversation: other_conversation, account: other_account, message_type: :outgoing, status: :delivered)

      described_class.preload([pending_conversation, other_conversation])

      expect(pending_conversation.successful_outgoing_count).to eq(0)
      expect(other_conversation.successful_outgoing_count).to eq(1)
    end

    it 'leaves the count nil when the conversation was not preloaded' do
      create(:message, conversation: empty_conversation, account: account, message_type: :outgoing, status: :sent)

      expect(empty_conversation.successful_outgoing_count).to be_nil
    end

    it 'uses one grouped query for every conversation on the page' do
      conversations = create_list(:conversation, 4, account: account)
      conversations.each do |conversation|
        create(:message, conversation: conversation, account: account, message_type: :outgoing, status: :sent)
      end

      count_queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _started, _finished, _id, payload|
        sql = payload[:sql]
        next if payload[:cached] || payload[:name] == 'SCHEMA'
        next unless sql.match?(/count\(/i) && sql.include?('message_type') && sql.include?('messages')

        count_queries << sql
      end

      described_class.preload(conversations)

      expect(count_queries.size).to eq(1)
      expect(count_queries.first).to include('GROUP BY')
      expect(count_queries.first).to include('account_id')
      expect(conversations.map(&:successful_outgoing_count)).to all(eq(1))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
