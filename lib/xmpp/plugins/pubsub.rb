require "rexml/document"
require "rexml/formatters/default"

require_relative "../xml_helpers"
require_relative "../plugin"

module Xmpp
  module Plugins
    class Pubsub < Xmpp::Plugin
      include Xmpp::XmlHelpers

      Namespace          = "http://jabber.org/protocol/pubsub"
      OwnerNs            = "#{Namespace}#owner"
      EventNs            = "#{Namespace}#event"
      NodeConfigNs       = "#{Namespace}#node_config"
      SubscribeOptionsNs = "#{Namespace}#subscribe_options"
      DiscoItemsNs       = "http://jabber.org/protocol/disco#items"
      DataFormNs         = "jabber:x:data"

      EVENTS = %i[
        item_published
        item_retracted
        node_deleted
        node_purged
        configuration_change
        subscription_change
      ].freeze

      def self.plugin_id
        :pubsub
      end

      def initialize(client, service_host: nil)
        super(client)
        @service_host = service_host
        @callbacks = Hash.new { |h, k| h[k] = [] }
      end

      def service_host
        @service_host ||= "pubsub.#{client_domain}"
      end

      EVENTS.each do |event|
        define_method("on_#{event}") do |&block|
          @callbacks[event] << block if block
          self
        end
      end

      def create_node(node, config: nil)
        configure_xml = if config && !config.empty?
          form = build_x_data_form(form_type: NodeConfigNs, fields: config)
          "<configure>#{form}</configure>"
        else
          ""
        end
        body = "<pubsub xmlns='#{Namespace}'><create node='#{escape_attr(node)}'/>#{configure_xml}</pubsub>"
        iq = send_iq(service_host, "set", "pubsub_create", body)
        pubsub_el = child_by_name(iq, "pubsub")
        create_el = child_by_name(pubsub_el, "create")
        actual = create_el&.attributes&.[]("node") || node
        { node: actual }
      end

      def delete_node(node)
        body = "<pubsub xmlns='#{OwnerNs}'><delete node='#{escape_attr(node)}'/></pubsub>"
        send_iq(service_host, "set", "pubsub_delete", body)
        true
      end

      def purge_node(node)
        body = "<pubsub xmlns='#{OwnerNs}'><purge node='#{escape_attr(node)}'/></pubsub>"
        send_iq(service_host, "set", "pubsub_purge", body)
        true
      end

      def publish(node, payload_xml, item_id: nil)
        item_attrs = item_id ? " id='#{escape_attr(item_id)}'" : ""
        body = "<pubsub xmlns='#{Namespace}'><publish node='#{escape_attr(node)}'><item#{item_attrs}>#{payload_xml}</item></publish></pubsub>"
        iq = send_iq(service_host, "set", "pubsub_publish", body)
        pubsub_el = child_by_name(iq, "pubsub")
        publish_el = child_by_name(pubsub_el, "publish")
        item_el = child_by_name(publish_el, "item")
        { node: node, item_id: item_el&.attributes&.[]("id") || item_id }
      end

      def retract(node, item_id, notify: true)
        notify_attr = notify ? " notify='true'" : " notify='false'"
        body = "<pubsub xmlns='#{Namespace}'><retract node='#{escape_attr(node)}'#{notify_attr}><item id='#{escape_attr(item_id)}'/></retract></pubsub>"
        send_iq(service_host, "set", "pubsub_retract", body)
        true
      end

      def items(node, max_items: nil, item_ids: nil)
        raise ArgumentError, "max_items and item_ids are mutually exclusive" if max_items && item_ids

        attrs = +"node='#{escape_attr(node)}'"
        attrs << " max_items='#{max_items.to_i}'" if max_items
        inner = Array(item_ids).map { |id| "<item id='#{escape_attr(id)}'/>" }.join
        body = "<pubsub xmlns='#{Namespace}'><items #{attrs}>#{inner}</items></pubsub>"
        iq = send_iq(service_host, "get", "pubsub_items", body)
        pubsub_el = child_by_name(iq, "pubsub")
        items_el = child_by_name(pubsub_el, "items")
        parse_items(items_el)
      end

      def subscribe(node, jid: nil)
        target_jid = jid || @client.jid
        body = "<pubsub xmlns='#{Namespace}'><subscribe node='#{escape_attr(node)}' jid='#{escape_attr(target_jid)}'/></pubsub>"
        iq = send_iq(service_host, "set", "pubsub_sub", body)
        pubsub_el = child_by_name(iq, "pubsub")
        sub_el = child_by_name(pubsub_el, "subscription")
        {
          node: sub_el&.attributes&.[]("node") || node,
          jid: sub_el&.attributes&.[]("jid") || target_jid,
          subid: sub_el&.attributes&.[]("subid"),
          subscription: sub_el&.attributes&.[]("subscription")
        }
      end

      def unsubscribe(node, jid: nil, subid: nil)
        target_jid = jid || @client.jid
        subid_attr = subid ? " subid='#{escape_attr(subid)}'" : ""
        body = "<pubsub xmlns='#{Namespace}'><unsubscribe node='#{escape_attr(node)}' jid='#{escape_attr(target_jid)}'#{subid_attr}/></pubsub>"
        send_iq(service_host, "set", "pubsub_unsub", body)
        true
      end

      def subscriptions(node: nil)
        if node
          body = "<pubsub xmlns='#{OwnerNs}'><subscriptions node='#{escape_attr(node)}'/></pubsub>"
          iq = send_iq(service_host, "get", "pubsub_subs_owner", body)
        else
          body = "<pubsub xmlns='#{Namespace}'><subscriptions/></pubsub>"
          iq = send_iq(service_host, "get", "pubsub_subs", body)
        end
        pubsub_el = child_by_name(iq, "pubsub")
        subs_el = child_by_name(pubsub_el, "subscriptions")
        parse_subscriptions(subs_el, default_node: node)
      end

      def affiliations(node: nil)
        if node
          body = "<pubsub xmlns='#{OwnerNs}'><affiliations node='#{escape_attr(node)}'/></pubsub>"
          iq = send_iq(service_host, "get", "pubsub_affs_owner", body)
        else
          body = "<pubsub xmlns='#{Namespace}'><affiliations/></pubsub>"
          iq = send_iq(service_host, "get", "pubsub_affs", body)
        end
        pubsub_el = child_by_name(iq, "pubsub")
        affs_el = child_by_name(pubsub_el, "affiliations")
        parse_affiliations(affs_el, default_node: node)
      end

      def set_affiliations(node, changes:)
        inner = Array(changes).map do |change|
          jid = change[:jid] || change["jid"]
          aff = change[:affiliation] || change["affiliation"]
          "<affiliation jid='#{escape_attr(jid)}' affiliation='#{escape_attr(aff)}'/>"
        end.join
        body = "<pubsub xmlns='#{OwnerNs}'><affiliations node='#{escape_attr(node)}'>#{inner}</affiliations></pubsub>"
        send_iq(service_host, "set", "pubsub_set_affs", body)
        true
      end

      def discover_nodes(node: nil)
        node_attr = node ? " node='#{escape_attr(node)}'" : ""
        body = "<query xmlns='#{DiscoItemsNs}'#{node_attr}/>"
        iq = send_iq(service_host, "get", "pubsub_disco", body)
        parse_disco_items(child_by_name(iq, "query"))
      end

      def get_node_configuration(node)
        body = "<pubsub xmlns='#{OwnerNs}'><configure node='#{escape_attr(node)}'/></pubsub>"
        iq = send_iq(service_host, "get", "pubsub_get_config", body)
        pubsub_el = child_by_name(iq, "pubsub")
        configure_el = child_by_name(pubsub_el, "configure")
        x_el = child_by_name(configure_el, "x")
        parse_x_data_form(x_el)
      end

      def set_node_configuration(node, fields)
        form = build_x_data_form(form_type: NodeConfigNs, fields: fields)
        body = "<pubsub xmlns='#{OwnerNs}'><configure node='#{escape_attr(node)}'>#{form}</configure></pubsub>"
        send_iq(service_host, "set", "pubsub_set_config", body)
        true
      end

      def on_stanza(stanza)
        return unless stanza.name == "message"
        event_el = child_by_name(stanza, "event")
        return unless event_el && namespaced?(event_el, EventNs)

        service = stanza.attributes["from"]
        items_el  = child_by_name(event_el, "items")
        delete_el = child_by_name(event_el, "delete")
        purge_el  = child_by_name(event_el, "purge")
        config_el = child_by_name(event_el, "configuration")
        sub_el    = child_by_name(event_el, "subscription")

        if items_el
          node = items_el.attributes["node"]
          items_el.elements.each("item") do |item|
            emit(:item_published,
                 service: service, node: node,
                 item_id: item.attributes["id"],
                 publisher: item.attributes["publisher"],
                 payload_xml: inner_xml(item))
          end
          items_el.elements.each("retract") do |r|
            emit(:item_retracted,
                 service: service, node: node, item_id: r.attributes["id"])
          end
        elsif delete_el
          redirect_el = child_by_name(delete_el, "redirect")
          emit(:node_deleted,
               service: service,
               node: delete_el.attributes["node"],
               redirect_uri: redirect_el&.attributes&.[]("uri"))
        elsif purge_el
          emit(:node_purged,
               service: service, node: purge_el.attributes["node"])
        elsif config_el
          emit(:configuration_change,
               service: service, node: config_el.attributes["node"])
        elsif sub_el
          emit(:subscription_change,
               service: service,
               node: sub_el.attributes["node"],
               jid: sub_el.attributes["jid"],
               subid: sub_el.attributes["subid"],
               subscription: sub_el.attributes["subscription"])
        end
      end

      private

      def client_domain
        @client.jid.to_s.split("@", 2).last
      end

      def send_iq(target, type, id_prefix, body_xml)
        id = @client.next_iq_id(id_prefix)
        xml = "<iq type='#{type}' id='#{escape_attr(id)}' to='#{escape_attr(target)}'>#{body_xml}</iq>"
        iq = @client.request_iq(id: id, xml: xml, allow_reconnect: true)
        raise_iq_error(iq, "PubSub request error") if iq.attributes["type"] == "error"
        iq
      end

      def inner_xml(element)
        return "" unless element
        formatter = REXML::Formatters::Default.new
        element.children.map do |child|
          out = +""
          formatter.write(child, out)
          out
        end.join
      end

      def build_x_data_form(form_type:, fields:, type: "submit")
        field_xml = +"<field var='FORM_TYPE' type='hidden'><value>#{escape_text(form_type)}</value></field>"
        fields.each do |var, value|
          values = Array(value)
          value_xml = values.map { |v| "<value>#{escape_text(v)}</value>" }.join
          field_xml << "<field var='#{escape_attr(var)}'>#{value_xml}</field>"
        end
        "<x xmlns='#{DataFormNs}' type='#{escape_attr(type)}'>#{field_xml}</x>"
      end

      def parse_x_data_form(x_el)
        return { form_type: nil, fields: {} } unless x_el
        form_type = nil
        fields = {}
        x_el.elements.each("field") do |field|
          var = field.attributes["var"]
          values = []
          field.elements.each("value") { |v| values << v.text }
          if var == "FORM_TYPE"
            form_type = values.first
          else
            fields[var] = values.length > 1 ? values : values.first
          end
        end
        { form_type: form_type, fields: fields }
      end

      def parse_items(items_el)
        return [] unless items_el
        out = []
        items_el.elements.each("item") do |item|
          out << {
            id: item.attributes["id"],
            publisher: item.attributes["publisher"],
            payload_xml: inner_xml(item)
          }
        end
        out
      end

      def parse_subscriptions(subs_el, default_node: nil)
        return [] unless subs_el
        out = []
        subs_el.elements.each("subscription") do |s|
          out << {
            node: s.attributes["node"] || default_node,
            jid: s.attributes["jid"],
            subid: s.attributes["subid"],
            subscription: s.attributes["subscription"]
          }
        end
        out
      end

      def parse_affiliations(affs_el, default_node: nil)
        return [] unless affs_el
        out = []
        affs_el.elements.each("affiliation") do |a|
          entry = {
            node: a.attributes["node"] || default_node,
            affiliation: a.attributes["affiliation"]
          }
          jid = a.attributes["jid"]
          entry[:jid] = jid if jid
          out << entry
        end
        out
      end

      def parse_disco_items(query_el)
        return [] unless query_el
        items = []
        query_el.elements.each("item") do |item|
          items << {
            jid: item.attributes["jid"],
            node: item.attributes["node"],
            name: item.attributes["name"]
          }
        end
        items
      end

      def emit(event, payload)
        emit_callbacks(@callbacks, event, payload)
      end
    end
  end
end
