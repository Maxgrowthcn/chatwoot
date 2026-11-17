require 'rails_helper'

RSpec.describe 'Conversation successful outgoing counts', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:headers) { admin.create_new_auth_token }

  def count_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql if sql.include?('COUNT(*) AS "count_all", "messages"."conversation_id"')
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  describe 'GET /api/v1/accounts/:account_id/conversations' do
    it 'returns a real zero or the successful count from one query for the page' do
      counted = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      empty = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      3.times do
        conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
        create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, status: :delivered)
      end
      create(:message, conversation: counted, account: account, inbox: inbox, message_type: :outgoing, status: :sent)
      create(:message, conversation: counted, account: account, inbox: inbox, message_type: :outgoing, status: :read)
      create(:message, conversation: counted, account: account, inbox: inbox, message_type: :outgoing, status: :failed)
      create(:message, conversation: counted, account: account, inbox: inbox, message_type: :incoming, status: :sent)
      create(:message, conversation: counted, account: account, inbox: inbox, message_type: :outgoing, private: true, status: :sent)

      queries = count_queries do
        get "/api/v1/accounts/#{account.id}/conversations", headers: headers, as: :json
      end

      expect(response).to have_http_status(:success)
      payload = response.parsed_body.dig('data', 'payload').index_by { |item| item['id'] }
      expect(payload.size).to eq(5)
      expect(payload[counted.display_id]['successful_outgoing_count']).to eq(2)
      expect(payload[empty.display_id]['successful_outgoing_count']).to eq(0)
      expect(queries.size).to eq(1)
      expect(queries.first).to include('GROUP BY')
      expect(queries.first).to include('account_id')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/conversations/filter' do
    it 'includes the preloaded count on filtered conversations' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, status: :sent)

      queries = count_queries do
        post "/api/v1/accounts/#{account.id}/conversations/filter",
             headers: headers,
             params: { payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'] }] },
             as: :json
      end

      expect(response).to have_http_status(:success)
      item = response.parsed_body['payload'].find { |row| row['id'] == conversation.display_id }
      expect(item['successful_outgoing_count']).to eq(1)
      expect(queries.size).to eq(1)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/search' do
    it 'includes the preloaded count on search results' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, status: :delivered,
                       content: 'hanyang-outgoing-reply')

      queries = count_queries do
        get "/api/v1/accounts/#{account.id}/conversations/search",
            headers: headers,
            params: { q: 'hanyang-outgoing-reply' },
            as: :json
      end

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].first['successful_outgoing_count']).to eq(1)
      expect(queries.size).to eq(1)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/:id' do
    it 'returns the preloaded count for the conversation' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, status: :read)

      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['successful_outgoing_count']).to eq(1)
    end

    it 'returns zero when the conversation has no successful public outgoing reply' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['successful_outgoing_count']).to eq(0)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/contacts/:id/conversations' do
    it 'includes the preloaded count without a per-conversation query' do
      first_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      second_conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, conversation: first_conversation, account: account, inbox: inbox, message_type: :outgoing, status: :sent)
      create(:message, conversation: first_conversation, account: account, inbox: inbox, message_type: :outgoing, status: :delivered)

      queries = count_queries do
        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: headers, as: :json
      end

      expect(response).to have_http_status(:success)
      payload = response.parsed_body['payload'].index_by { |item| item['id'] }
      expect(payload[first_conversation.display_id]['successful_outgoing_count']).to eq(2)
      expect(payload[second_conversation.display_id]['successful_outgoing_count']).to eq(0)
      expect(queries.size).to eq(1)
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/conversations/:id' do
    it 'omits a fabricated zero when the count was not preloaded' do
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, status: :sent)

      patch "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: headers,
            params: { priority: 'high' },
            as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['successful_outgoing_count']).to be_nil
    end
  end
end
