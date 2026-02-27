require_relative "heyo_xmpp_client/version"

require_relative "xmpp/xml_helpers"
require_relative "xmpp/stream_parser"
require_relative "xmpp/plugin"
require_relative "xmpp/plugin_manager"
require_relative "xmpp/client"
require_relative "xmpp/plugins/mod_inbox"
require_relative "xmpp/plugins/token_reconnection"

module HeyoXmppClient
end
