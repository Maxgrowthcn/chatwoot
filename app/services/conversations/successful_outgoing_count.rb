class Conversations::SuccessfulOutgoingCount
  # Draft replies live in Redis, not messages. message_type template is a non-reply
  # (greeting, CSAT, out of office, auto-resolve), not an outgoing reply.
  SUCCESSFUL_STATUSES = %i[sent delivered read].freeze

  def self.preload(conversations)
    new(conversations).preload
  end

  def initialize(conversations)
    @records = conversation_records(conversations)
  end

  def preload
    return if @records.empty?

    counts = grouped_counts
    @records.each do |conversation|
      conversation.successful_outgoing_count = counts.fetch(conversation.id, 0)
    end
  end

  private

  def conversation_records(conversations)
    records = conversations.is_a?(ActiveRecord::Relation) ? conversations.load.to_a : Array(conversations)
    records.compact
  end

  def grouped_counts
    Message.unscope(:order)
           .where(account_conversation_scope)
           .where(message_type: :outgoing, private: false, status: SUCCESSFUL_STATUSES)
           .group(:conversation_id)
           .count
  end

  def account_conversation_scope
    table = Message.arel_table
    conditions = @records.group_by(&:account_id).map do |account_id, grouped|
      table[:account_id].eq(account_id).and(table[:conversation_id].in(grouped.map(&:id)))
    end
    conditions.reduce { |combined, condition| combined.or(condition) }
  end
end
