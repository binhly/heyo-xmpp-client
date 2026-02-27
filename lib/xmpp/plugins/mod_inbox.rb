require_relative "../xml_helpers"
require_relative "../plugin"

module Xmpp
  module Plugins
    class ModInbox < Xmpp::Plugin
      include Xmpp::XmlHelpers

      InboxNamespace = "erlang-solutions.com:xmpp:inbox:0"

      def self.plugin_id
        :mod_inbox
      end

      def summary
        id = @client.next_iq_id("inbox")
        xml = "<iq type='set' id='#{escape_attr(id)}'><inbox xmlns='#{InboxNamespace}'/></iq>"
        iq = @client.request_iq(id: id, xml: xml, allow_reconnect: true)
        raise_inbox_error(iq) if iq.attributes["type"] == "error"
        fin = child_by_name(iq, "fin")
        raise "Inbox response missing <fin>" unless fin
        {
          count: text_to_i(child_text(fin, "count")),
          unread_messages: text_to_i(child_text(fin, "unread-messages")),
          active_conversations: text_to_i(child_text(fin, "active-conversations"))
        }
      end

      def unread_count
        summary[:unread_messages]
      end

      private

      def raise_inbox_error(iq)
        error_text = iq.elements["error"]&.elements["text"]&.text
        raise(error_text || "Inbox query error")
      end
    end
  end
end
