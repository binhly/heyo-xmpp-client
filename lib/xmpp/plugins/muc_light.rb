require_relative "../xml_helpers"
require_relative "../plugin"

module Xmpp
  module Plugins
    class MucLight < Xmpp::Plugin
      include Xmpp::XmlHelpers

      Namespace = "urn:xmpp:muclight:0"
      AffiliationsNs = "#{Namespace}#affiliations"
      ConfigurationNs = "#{Namespace}#configuration"
      InfoNs = "#{Namespace}#info"
      CreateNs = "#{Namespace}#create"
      DestroyNs = "#{Namespace}#destroy"
      BlockingNs = "#{Namespace}#blocking"
      DiscoItemsNs = "http://jabber.org/protocol/disco#items"

      EVENTS = %i[
        message
        affiliation_change
        configuration_change
        room_created
        room_destroyed
      ].freeze

      def self.plugin_id
        :muc_light
      end

      def initialize(client, service_host: nil)
        super(client)
        @service_host = service_host
        @callbacks = Hash.new { |h, k| h[k] = [] }
      end

      def service_host
        @service_host ||= "muclight.#{client_domain}"
      end

      EVENTS.each do |event|
        define_method("on_#{event}") do |&block|
          @callbacks[event] << block if block
          self
        end
      end

      def create_room(name:, occupants: [], room_jid: nil, **config)
        target = room_jid || service_host
        body = build_create_body(name, occupants, config)
        iq = send_iq(target, "set", "muclight_create", body)
        { room_jid: iq.attributes["from"] || target }
      end

      def destroy_room(room_jid)
        send_iq(room_jid, "set", "muclight_destroy",
                "<query xmlns='#{DestroyNs}'/>")
        true
      end

      def get_configuration(room_jid, version: nil)
        body = "<query xmlns='#{ConfigurationNs}'>#{version_element(version)}</query>"
        iq = send_iq(room_jid, "get", "muclight_get_config", body)
        parse_configuration(child_by_name(iq, "query"))
      end

      def set_configuration(room_jid, **fields)
        children = fields.map { |k, v| "<#{k}>#{escape_text(v)}</#{k}>" }.join
        body = "<query xmlns='#{ConfigurationNs}'>#{children}</query>"
        send_iq(room_jid, "set", "muclight_set_config", body)
        true
      end

      def get_affiliations(room_jid, version: nil)
        body = "<query xmlns='#{AffiliationsNs}'>#{version_element(version)}</query>"
        iq = send_iq(room_jid, "get", "muclight_get_aff", body)
        parse_affiliations(child_by_name(iq, "query"))
      end

      def set_affiliations(room_jid, changes:)
        body = "<query xmlns='#{AffiliationsNs}'>#{build_user_elements(changes)}</query>"
        send_iq(room_jid, "set", "muclight_set_aff", body)
        true
      end

      def invite(room_jid, jids)
        set_affiliations(room_jid, changes: Array(jids).map { |j| { jid: j, affiliation: "member" } })
      end

      def kick(room_jid, jids)
        set_affiliations(room_jid, changes: Array(jids).map { |j| { jid: j, affiliation: "none" } })
      end

      def promote(room_jid, jid)
        set_affiliations(room_jid, changes: [{ jid: jid, affiliation: "owner" }])
      end

      def leave(room_jid)
        set_affiliations(room_jid, changes: [{ jid: @client.jid, affiliation: "none" }])
      end

      def rooms
        body = "<query xmlns='#{DiscoItemsNs}'/>"
        iq = send_iq(service_host, "get", "muclight_rooms", body)
        parse_disco_items(child_by_name(iq, "query"))
      end

      def room_info(room_jid, version: nil)
        body = "<query xmlns='#{InfoNs}'>#{version_element(version)}</query>"
        iq = send_iq(room_jid, "get", "muclight_info", body)
        parse_info(child_by_name(iq, "query"))
      end

      def send_groupchat_message(room_jid, body)
        xml = "<message type='groupchat' to='#{escape_attr(room_jid)}'><body>#{escape_text(body)}</body></message>"
        @client.send_raw(xml)
      end

      def blocking_list
        body = "<query xmlns='#{BlockingNs}'/>"
        iq = send_iq(service_host, "get", "muclight_block_list", body)
        parse_blocking(child_by_name(iq, "query"))
      end

      def block(jids: [], rooms: [])
        change_blocking(jids: jids, rooms: rooms, action: "deny", id_prefix: "muclight_block")
      end

      def unblock(jids: [], rooms: [])
        change_blocking(jids: jids, rooms: rooms, action: "allow", id_prefix: "muclight_unblock")
      end

      def on_stanza(stanza)
        return unless stanza.name == "message"
        return unless stanza.attributes["type"] == "groupchat"

        affiliations_x = find_x(stanza, AffiliationsNs)
        destroy_x = find_x(stanza, DestroyNs)
        config_x = find_x(stanza, ConfigurationNs)

        if destroy_x
          emit(:room_destroyed, destroy_payload(stanza, affiliations_x))
        elsif affiliations_x
          payload = affiliation_payload(stanza, affiliations_x)
          event = payload[:prev_version] ? :affiliation_change : :room_created
          emit(event, payload)
        elsif config_x
          emit(:configuration_change, configuration_payload(stanza, config_x))
        else
          body_el = child_by_name(stanza, "body")
          emit(:message, message_payload(stanza, body_el)) if body_el && !body_el.text.to_s.empty?
        end
      end

      private

      def client_domain
        @client.jid.to_s.split("@", 2).last
      end

      def change_blocking(jids:, rooms:, action:, id_prefix:)
        users_xml = Array(jids).map { |j| "<user action='#{action}'>#{escape_text(j)}</user>" }.join
        rooms_xml = Array(rooms).map { |r| "<room action='#{action}'>#{escape_text(r)}</room>" }.join
        body = "<query xmlns='#{BlockingNs}'>#{users_xml}#{rooms_xml}</query>"
        send_iq(service_host, "set", id_prefix, body)
        true
      end

      def send_iq(target, type, id_prefix, body_xml)
        id = @client.next_iq_id(id_prefix)
        xml = "<iq type='#{type}' id='#{escape_attr(id)}' to='#{escape_attr(target)}'>#{body_xml}</iq>"
        iq = @client.request_iq(id: id, xml: xml, allow_reconnect: true)
        raise_muc_light_error(iq) if iq.attributes["type"] == "error"
        iq
      end

      def version_element(version)
        version ? "<version>#{escape_text(version)}</version>" : ""
      end

      def build_create_body(name, occupants, config)
        config_children = +"<roomname>#{escape_text(name)}</roomname>"
        config.each do |k, v|
          config_children << "<#{k}>#{escape_text(v)}</#{k}>"
        end
        occupants_xml = if Array(occupants).empty?
          ""
        else
          inner = Array(occupants).map do |entry|
            jid, affiliation = if entry.is_a?(Hash)
              [entry[:jid] || entry["jid"], entry[:affiliation] || entry["affiliation"] || "member"]
            else
              [entry, "member"]
            end
            "<user affiliation='#{escape_attr(affiliation)}'>#{escape_text(jid)}</user>"
          end.join
          "<occupants>#{inner}</occupants>"
        end
        "<query xmlns='#{CreateNs}'><configuration>#{config_children}</configuration>#{occupants_xml}</query>"
      end

      def build_user_elements(changes)
        Array(changes).map do |change|
          jid = change[:jid] || change["jid"]
          aff = change[:affiliation] || change["affiliation"]
          "<user affiliation='#{escape_attr(aff)}'>#{escape_text(jid)}</user>"
        end.join
      end

      def parse_affiliations(query_el)
        return { version: nil, users: [] } unless query_el
        { version: child_text(query_el, "version"), users: parse_users(query_el) }
      end

      def parse_configuration(query_el)
        return { version: nil, fields: {} } unless query_el
        fields = {}
        query_el.elements.each do |el|
          next if el.name == "version"
          fields[el.name.to_sym] = el.text
        end
        { version: child_text(query_el, "version"), fields: fields }
      end

      def parse_info(query_el)
        return { version: nil, configuration: {}, users: [] } unless query_el
        config_el = child_by_name(query_el, "configuration")
        occupants_el = child_by_name(query_el, "occupants")
        config = {}
        config_el&.elements&.each { |el| config[el.name.to_sym] = el.text }
        {
          version: child_text(query_el, "version"),
          configuration: config,
          users: parse_users(occupants_el)
        }
      end

      def parse_disco_items(query_el)
        return [] unless query_el
        items = []
        query_el.elements.each("item") do |item|
          items << {
            jid: item.attributes["jid"],
            name: item.attributes["name"],
            version: item.attributes["version"]
          }
        end
        items
      end

      def parse_blocking(query_el)
        return { users: [], rooms: [] } unless query_el
        users = []
        rooms = []
        query_el.elements.each do |el|
          payload = { jid: el.text, action: el.attributes["action"] }
          case el.name
          when "user" then users << payload
          when "room" then rooms << payload
          end
        end
        { users: users, rooms: rooms }
      end

      def parse_users(parent)
        return [] unless parent
        users = []
        parent.elements.each("user") do |u|
          users << { jid: u.text, affiliation: u.attributes["affiliation"] }
        end
        users
      end

      def find_x(message, namespace)
        message.elements.each("x") do |x|
          return x if x.attributes["xmlns"] == namespace
        end
        nil
      end

      def split_from(message)
        full = message.attributes["from"].to_s
        full.split("/", 2)
      end

      def message_payload(stanza, body_el)
        room_jid, sender = split_from(stanza)
        { room_jid: room_jid, from: sender, body: body_el.text }
      end

      def affiliation_payload(stanza, x)
        room_jid, _ = split_from(stanza)
        {
          room_jid: room_jid,
          version: child_text(x, "version"),
          prev_version: child_text(x, "prev-version"),
          users: parse_users(x)
        }
      end

      def configuration_payload(stanza, x)
        room_jid, _ = split_from(stanza)
        fields = {}
        x.elements.each do |el|
          next if %w[version prev-version].include?(el.name)
          fields[el.name.to_sym] = el.text
        end
        {
          room_jid: room_jid,
          version: child_text(x, "version"),
          prev_version: child_text(x, "prev-version"),
          fields: fields
        }
      end

      def destroy_payload(stanza, affiliations_x)
        room_jid, _ = split_from(stanza)
        { room_jid: room_jid, users: parse_users(affiliations_x) }
      end

      def emit(event, payload)
        @callbacks[event].each do |cb|
          begin
            cb.call(payload)
          rescue StandardError
            # per-callback isolation: a misbehaving listener must not
            # stop sibling listeners or the parser thread.
          end
        end
      end

      def raise_muc_light_error(iq)
        error_text = iq.elements["error"]&.elements["text"]&.text
        raise(error_text || "MUC Light request error")
      end
    end
  end
end
